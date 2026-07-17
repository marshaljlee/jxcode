import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxcode/blocs/settings/settings_bloc.dart';
import 'package:jxcode/models/permission_request.dart';

void main() {
  group('SettingsBloc', () {
    test('initial state has default values', () {
      final bloc = SettingsBloc();
      expect(bloc.state.themeMode, ThemeMode.system);
      expect(bloc.state.defaultModel, 'claude-sonnet-5');
      expect(bloc.state.permissionMode, PermissionMode.interactive);
      bloc.close();
    });

    test('setThemeMode updates state', () {
      final bloc = SettingsBloc();
      bloc.setThemeMode(ThemeMode.dark);
      expect(bloc.state.themeMode, ThemeMode.dark);
      bloc.close();
    });

    test('updatePermissionMode updates state', () {
      final bloc = SettingsBloc();
      bloc.updatePermissionMode(PermissionMode.moderate);
      expect(bloc.state.permissionMode, PermissionMode.moderate);
      bloc.close();
    });
  });
}
