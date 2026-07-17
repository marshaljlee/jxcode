import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A small coloured dot indicating connection or proxy status.
class ConnectionDot extends StatelessWidget {
  final double size;
  final Color? color;
  final bool isActive;
  final double latency;

  const ConnectionDot({
    super.key,
    this.size = 8,
    this.color,
    this.isActive = false,
    this.latency = 0,
  });

  Color _resolveColor() {
    if (color != null) return color!;
    if (!isActive) return JXCODETheme.error;
    if (latency > 0 && latency < 100) return JXCODETheme.success;
    if (latency >= 100 && latency < 500) return JXCODETheme.warning;
    if (latency >= 500) return JXCODETheme.warning.withValues(alpha: 0.8);
    return JXCODETheme.success;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _resolveColor(),
        shape: BoxShape.circle,
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: _resolveColor().withValues(alpha: 0.4),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
    );
  }
}

/// Badge that displays the permission mode (Safe / Moderate / High).
class PermissionBadge extends StatelessWidget {
  final String label;

  const PermissionBadge({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final Color badgeColor;
    switch (label.toLowerCase()) {
      case 'safe':
      case 'approveall':
        badgeColor = JXCODETheme.success;
      case 'moderate':
      case 'high':
        badgeColor = JXCODETheme.warning;
      case 'custom':
      case 'denyall':
        badgeColor = JXCODETheme.error;
      default:
        badgeColor = JXCODETheme.info;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
      ),
      child: Text(
        label[0].toUpperCase() + label.substring(1),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: badgeColor,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// Displays the model name in a compact chip.
class ModelChip extends StatelessWidget {
  final String model;
  final double fontSize;

  const ModelChip({super.key, required this.model, this.fontSize = 11});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        model,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: theme.colorScheme.onPrimaryContainer,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// Indicates that a response is being streamed in.
class StreamingIndicator extends StatefulWidget {
  const StreamingIndicator({super.key});

  @override
  State<StreamingIndicator> createState() => _StreamingIndicatorState();
}

class _StreamingIndicatorState extends State<StreamingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final delay = i * 200;
            final t = (_controller.value * 1200 - delay).clamp(0, 1200) / 1200;
            final opacity = (t * 2).clamp(0.0, 1.0) * (1 - (t * 2).clamp(0.0, 1.0));
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: opacity),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// Displays the current permission mode as a compact label.
class ModeLabel extends StatelessWidget {
  final String mode;

  const ModeLabel({super.key, required this.mode});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        mode,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSecondaryContainer,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
