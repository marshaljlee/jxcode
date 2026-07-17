import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxcode/app.dart';
import 'package:jxcode/blocs/settings/settings_bloc.dart';
import 'package:jxcode/services/project_repository.dart';
import 'package:jxcode/services/session_repository.dart';

void main() {
  testWidgets('JXCODE app renders shell', (WidgetTester tester) async {
    await tester.pumpWidget(JXCODEApp(
      settingsBloc: SettingsBloc(),
      projectRepo: ProjectRepository(),
      sessionRepo: SessionRepository(),
    ));

    // Verify the app shell renders with navigation elements.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
