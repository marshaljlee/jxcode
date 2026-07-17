import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'blocs/settings/settings_bloc.dart';
import 'blocs/chat/chat_bloc.dart';
import 'blocs/project/project_bloc.dart';
import 'blocs/session/session_bloc.dart';
import 'blocs/permission/permission_bloc.dart';
import 'blocs/proxy/proxy_bloc.dart';
import 'routing/app_router.dart';
import 'services/project_repository.dart';
import 'services/session_repository.dart';
import 'services/claude_service.dart';
import 'services/permission_server.dart';
import 'theme/app_theme.dart';

class JXCODEApp extends StatelessWidget {
  final SettingsBloc settingsBloc;
  final ProjectRepository projectRepo;
  final SessionRepository sessionRepo;

  const JXCODEApp({
    super.key,
    required this.settingsBloc,
    required this.projectRepo,
    required this.sessionRepo,
  });

  @override
  Widget build(BuildContext context) {
    final claudeService = ClaudeService();
    final permissionServer = PermissionServer();
    final proxyBloc = ProxyBloc();
    final chatBloc = ChatBloc(
      claudeService: claudeService,
      sessionRepo: sessionRepo,
      proxyBloc: proxyBloc,
    );
    final projectBloc = ProjectBloc(repository: projectRepo);
    final sessionBloc = SessionBloc(repository: sessionRepo);
    final permissionBloc = PermissionBloc(permissionServer: permissionServer);

    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: settingsBloc),
        BlocProvider.value(value: chatBloc),
        BlocProvider.value(value: projectBloc),
        BlocProvider.value(value: sessionBloc),
        BlocProvider.value(value: permissionBloc),
        BlocProvider.value(value: proxyBloc),
      ],
      child: BlocBuilder<SettingsBloc, SettingsState>(
        builder: (context, state) {
          return MaterialApp.router(
            title: 'JXCODE',
            debugShowCheckedModeBanner: false,
            theme: JXCODETheme.lightTheme,
            darkTheme: JXCODETheme.darkTheme,
            themeMode: state.themeMode,
            routerConfig: appRouter,
          );
        },
      ),
    );
  }
}
