import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../pages/auth/onboarding_page.dart';
import '../pages/chat/chat_page.dart';
import '../pages/home_page.dart';
import '../pages/projects/project_detail_page.dart';
import '../pages/projects/project_list_page.dart';
import '../pages/settings/settings_page.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
final GlobalKey<NavigatorState> _shellNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'shell');

final GoRouter appRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/onboarding',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const OnboardingPage(),
    ),
    ShellRoute(
      navigatorKey: _shellNavigatorKey,
      builder: (context, state, child) => HomePage(child: child),
      routes: [
        GoRoute(
          path: '/',
          redirect: (context, state) => '/chat',
        ),
        GoRoute(
          path: '/chat',
          builder: (context, state) => const ChatPage(),
          routes: [
            GoRoute(
              path: 'new',
              parentNavigatorKey: _rootNavigatorKey,
              builder: (context, state) => const ChatPage(),
            ),
            GoRoute(
              path: ':sessionId',
              parentNavigatorKey: _rootNavigatorKey,
              builder: (context, state) {
                final sessionId = state.pathParameters['sessionId']!;
                return ChatPage(sessionId: sessionId);
              },
            ),
          ],
        ),
        GoRoute(
          path: '/projects',
          builder: (context, state) => const ProjectListPage(),
          routes: [
            GoRoute(
              path: ':id',
              parentNavigatorKey: _rootNavigatorKey,
              builder: (context, state) {
                final id = state.pathParameters['id']!;
                return ProjectDetailPage(projectId: id);
              },
            ),
          ],
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsPage(),
        ),
        GoRoute(
          path: '/terminal',
          builder: (context, state) => const _TerminalPlaceholder(),
        ),
      ],
    ),
  ],
);

/// Temporary terminal stub until a dedicated TerminalPage is built.
class _TerminalPlaceholder extends StatelessWidget {
  const _TerminalPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Terminal')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal_rounded, size: 64, color: theme.colorScheme.primary.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text(
              'Built-in terminal coming soon',
              style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              'Use the macOS Terminal app for now.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
            ),
          ],
        ),
      ),
    );
  }
}
