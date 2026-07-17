import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/permission_request.dart';

class SettingsState {
  final ThemeMode themeMode;
  final String defaultModel;
  final String defaultEffort;
  final PermissionMode permissionMode;

  const SettingsState({
    required this.themeMode,
    required this.defaultModel,
    required this.defaultEffort,
    required this.permissionMode,
  });

  factory SettingsState.initial() => const SettingsState(
        themeMode: ThemeMode.system,
        defaultModel: 'claude-sonnet-5',
        defaultEffort: 'auto',
        permissionMode: PermissionMode.interactive,
      );

  SettingsState copyWith({
    ThemeMode? themeMode,
    String? defaultModel,
    String? defaultEffort,
    PermissionMode? permissionMode,
  }) {
    return SettingsState(
      themeMode: themeMode ?? this.themeMode,
      defaultModel: defaultModel ?? this.defaultModel,
      defaultEffort: defaultEffort ?? this.defaultEffort,
      permissionMode: permissionMode ?? this.permissionMode,
    );
  }
}

class SettingsBloc extends Cubit<SettingsState> {
  SettingsBloc() : super(SettingsState.initial());

  Future<void> load() async {
    emit(SettingsState.initial());
  }

  void setThemeMode(ThemeMode mode) => emit(state.copyWith(themeMode: mode));

  void updateModel(String model) =>
      emit(state.copyWith(defaultModel: model));

  void updateEffort(String effort) =>
      emit(state.copyWith(defaultEffort: effort));

  void updatePermissionMode(PermissionMode mode) =>
      emit(state.copyWith(permissionMode: mode));
}
