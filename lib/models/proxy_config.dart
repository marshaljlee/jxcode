import 'package:equatable/equatable.dart';

/// LLM provider supported by jxproxy.
///
/// Aligned with the Swift [ProxyConfig.Provider] enum so routing config
/// is consistent across macOS and Android.
enum ProxyProvider {
  /// Anthropic Direct — own API key.
  direct,

  /// OpenRouter — routes through openrouter.ai.
  openrouter,

  /// OpenCode Zen / Big-Pickle.
  opencodeZen,

  /// OpenCode Go.
  opencodeGo,

  /// Google / Gemini.
  google,

  /// Nvidia NIM.
  nvidia,

  /// Nemotron 3 Ultra (via Nvidia).
  nemotron,

  /// Local / Ollama.
  local,

  /// Generic custom provider.
  custom;

  /// Human-readable label for UI dropdowns.
  String get displayName {
    switch (this) {
      case ProxyProvider.direct:
        return 'Anthropic Direct';
      case ProxyProvider.openrouter:
        return 'OpenRouter';
      case ProxyProvider.opencodeZen:
        return 'OpenCode Zen / Big-Pickle';
      case ProxyProvider.opencodeGo:
        return 'OpenCode Go';
      case ProxyProvider.google:
        return 'Google / Gemini';
      case ProxyProvider.nvidia:
        return 'Nvidia NIM';
      case ProxyProvider.nemotron:
        return 'Nemotron 3 Ultra';
      case ProxyProvider.local:
        return 'Local / Ollama';
      case ProxyProvider.custom:
        return 'Custom';
    }
  }
}

/// Log level for the jxproxy server.
enum ProxyLogLevel { debug, info, warn, error }

/// Configuration for the jxproxy router.
///
/// Mirrors the Swift [ProxyConfig] from the macOS app to keep shared
/// proxy settings portable across platforms.
class ProxyConfig extends Equatable {
  /// Port jxproxy listens on. Default: 5255.
  final int port;

  /// Primary LLM provider.
  final ProxyProvider provider;

  /// Model name/identifier to use with the provider.
  final String model;

  /// API key for the selected provider.
  final String apiKey;

  /// Custom host override (used by [ProxyProvider.local] and [ProxyProvider.custom]).
  final String customHost;

  /// Ordered list of fallback providers to try when the primary fails.
  final List<ProxyProvider> fallbackProviders;

  /// Log verbosity for jxproxy.
  final ProxyLogLevel logLevel;

  /// HTTP request timeout in seconds.
  final int requestTimeoutSeconds;

  const ProxyConfig({
    this.port = 5255,
    this.provider = ProxyProvider.opencodeZen,
    this.model = 'claude-sonnet-4-6',
    this.apiKey = '',
    this.customHost = '',
    this.fallbackProviders = const [],
    this.logLevel = ProxyLogLevel.info,
    this.requestTimeoutSeconds = 60,
  });

  ProxyConfig copyWith({
    int? port,
    ProxyProvider? provider,
    String? model,
    String? apiKey,
    String? customHost,
    List<ProxyProvider>? fallbackProviders,
    ProxyLogLevel? logLevel,
    int? requestTimeoutSeconds,
  }) {
    return ProxyConfig(
      port: port ?? this.port,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      customHost: customHost ?? this.customHost,
      fallbackProviders: fallbackProviders ?? this.fallbackProviders,
      logLevel: logLevel ?? this.logLevel,
      requestTimeoutSeconds: requestTimeoutSeconds ?? this.requestTimeoutSeconds,
    );
  }

  /// Whether the selected provider requires an API key.
  bool get requiresKey => provider != ProxyProvider.local;

  @override
  List<Object?> get props => [
    port, provider, model, apiKey, customHost,
    fallbackProviders, logLevel, requestTimeoutSeconds,
  ];
}
