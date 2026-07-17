import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../blocs/permission/permission_bloc.dart';
import '../blocs/permission/permission_state.dart';
import '../blocs/project/project_bloc.dart';
import '../blocs/project/project_state.dart';
import '../blocs/proxy/proxy_bloc.dart';
import '../blocs/proxy/proxy_state.dart';
import '../blocs/session/session_bloc.dart';
import '../blocs/session/session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/sidebar.dart';
import 'permission/permission_modal.dart';

/// Scaffold with a bottom navigation bar and a drawer.
///
/// The [child] widget is provided by the ShellRoute and represents the
/// currently active tab content.
class HomePage extends StatelessWidget {
  final Widget child;

  const HomePage({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();

    int currentIndex;
    switch (true) {
      case final _ when location.startsWith('/projects'):
        currentIndex = 1;
      case final _ when location.startsWith('/settings'):
        currentIndex = 2;
      case final _ when location.startsWith('/terminal'):
        currentIndex = 3;
      default:
        currentIndex = 0;
    }

    return Scaffold(
      drawer: const AppDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: child),
            _buildBottomNav(context, currentIndex),
            _permissionOverlay(context),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNav(BuildContext context, int currentIndex) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: currentIndex,
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.transparent,
        selectedItemColor: JXCODETheme.terracotta,
        unselectedItemColor: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        elevation: 0,
        onTap: (index) {
          switch (index) {
            case 0:
              context.go('/chat');
            case 1:
              context.go('/projects');
            case 2:
              context.go('/settings');
            case 3:
              context.go('/terminal');
          }
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.chat_bubble_outline_rounded), label: 'Sessions'),
          BottomNavigationBarItem(icon: Icon(Icons.folder_outlined), label: 'Projects'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), label: 'Settings'),
          BottomNavigationBarItem(icon: Icon(Icons.terminal_rounded), label: 'Terminal'),
        ],
      ),
    );
  }

  /// Renders a permission approval dialog when there are pending requests.
  Widget _permissionOverlay(BuildContext context) {
    return BlocBuilder<PermissionBloc, PermissionState>(
      builder: (context, state) {
        if (state.pendingRequests.isEmpty) return const SizedBox.shrink();

        return PermissionModalOverlay(request: state.pendingRequests.first);
      },
    );
  }
}

/// Sidebar drawer — delegates to AppDrawerContent from sidebar.dart.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: 300,
      child: SafeArea(
        child: BlocBuilder<ProjectBloc, ProjectState>(
          builder: (context, projectState) {
            return BlocBuilder<ProxyBloc, ProxyState>(
              builder: (context, proxyState) {
                return BlocBuilder<SessionBloc, SessionState>(
                  builder: (context, sessionState) {
                    return AppDrawerContent(
                      currentProject: projectState.selectedProject,
                      recentSessions: sessionState.sessions.take(5).toList(),
                      proxyStatus: proxyState.status,
                      proxyLatency: proxyState.latency,
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}
