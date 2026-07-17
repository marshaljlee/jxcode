import 'package:equatable/equatable.dart';

import '../../models/proxy_config.dart';

class ProxyState extends Equatable {
  final String status;
  final ProxyConfig config;
  final double latency;
  final List<Map<String, dynamic>> logEntries;

  const ProxyState({
    this.status = 'stopped',
    this.config = const ProxyConfig(),
    this.latency = 0.0,
    this.logEntries = const [],
  });

  ProxyState copyWith({
    String? status,
    ProxyConfig? config,
    double? latency,
    List<Map<String, dynamic>>? logEntries,
  }) {
    return ProxyState(
      status: status ?? this.status,
      config: config ?? this.config,
      latency: latency ?? this.latency,
      logEntries: logEntries ?? this.logEntries,
    );
  }

  @override
  List<Object?> get props => [status, config, latency, logEntries];
}
