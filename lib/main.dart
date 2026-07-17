import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'blocs/settings/settings_bloc.dart';
import 'services/project_repository.dart';
import 'services/session_repository.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  final settingsBloc = SettingsBloc();
  await settingsBloc.load();

  final projectRepo = ProjectRepository();
  final sessionRepo = SessionRepository();

  runApp(JXCODEApp(
    settingsBloc: settingsBloc,
    projectRepo: projectRepo,
    sessionRepo: sessionRepo,
  ));
}
