import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/proxy_config.dart';
import 'proxy_state.dart';

class ProxyBloc extends Cubit<ProxyState> {
  Timer? _healthTimer;

  ProxyBloc() : super(const ProxyState());

  Future<void> start() async {
    emit(state.copyWith(status: 'starting'));
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      _startHealthCheck();
      emit(state.copyWith(status: 'running'));
    } catch (_) {
      emit(state.copyWith(status: 'failed'));
    }
  }

  Future<void> stop() async {
    _healthTimer?.cancel();
    _healthTimer = null;
    emit(state.copyWith(
      status: 'stopped',
      latency: 0.0,
    ));
  }

  void updateConfig(ProxyConfig config) {
    emit(state.copyWith(config: config));
  }

  Future<void> checkHealth() async {
    if (state.status != 'running') return;

    final lastLatency = state.latency;
    final now = DateTime.now();
    final entry = <String, dynamic>{
      'timestamp': now.toIso8601String(),
      'latency': lastLatency,
    };

    emit(state.copyWith(
      logEntries: [entry, ...state.logEntries].take(100).toList(),
    ));
  }

  void _startHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => checkHealth(),
    );
  }

  @override
  Future<void> close() {
    _healthTimer?.cancel();
    return super.close();
  }
}
