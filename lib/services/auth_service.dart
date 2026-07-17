import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

/// GitHub OAuth Device Flow authentication and secure token storage.
///
/// Manages:
///   - GitHub personal access token (OAuth Device Flow)
///   - Anthropic API key (for Claude proxy)
///   - Provider API keys (OpenAI, Google, custom)
///
/// All secrets are persisted via [flutter_secure_storage] which uses
/// the platform keychain (macOS Keychain / Android Keystore).
class AuthService {
  final FlutterSecureStorage _storage;
  final Dio _dio;
  final String Function()? clientIdOverride;

  static const _keyGithubToken = 'jxcode_github_token';
  static const _keyAnthropicKey = 'jxcode_anthropic_api_key';
  static const _keyOpenaiKey = 'jxcode_openai_api_key';
  static const _keyGoogleKey = 'jxcode_google_api_key';
  static const _keyCustomKey = 'jxcode_custom_api_key';
  static const _keyDeviceCode = 'jxcode_device_code';

  /// Default GitHub OAuth app client ID.
  ///
  /// Replace with your registered GitHub OAuth App client ID for
  /// production use.
  static const _defaultClientId = 'jxcode-cli-client';

  static const _githubAuthUrl = 'https://github.com/login/device/code';
  static const _githubTokenUrl = 'https://github.com/login/oauth/access_token';
  static const _githubUserUrl = 'https://api.github.com/user';

  AuthService({
    FlutterSecureStorage? storage,
    Dio? dio,
    this.clientIdOverride,
  })  : _storage = storage ??
            const FlutterSecureStorage(aOptions: AndroidOptions()),
        _dio = dio ?? Dio();

  // ---------------------------------------------------------------------------
  // GitHub OAuth Device Flow
  // ---------------------------------------------------------------------------

  /// Kicks off the GitHub Device Flow:
  ///   1. Requests a device code from GitHub
  ///   2. Opens the user's browser for authorisation
  ///   3. Polls GitHub until the user completes the flow
  ///
  /// Returns the access token on success. Throws on failure or timeout.
  Future<String> login({
    Duration pollInterval = const Duration(seconds: 5),
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final clientId = clientIdOverride?.call() ?? _defaultClientId;

    // Step 1: Request device code
    final deviceResp = await _dio.post(
      _githubAuthUrl,
      data: {'client_id': clientId, 'scope': 'repo read:user'},
      options: Options(
        headers: {'Accept': 'application/json', 'User-Agent': 'jxcode'},
        contentType: 'application/json',
      ),
    );

    final deviceData = deviceResp.data as Map<String, dynamic>;
    final deviceCode = deviceData['device_code'] as String;
    final verificationUri = deviceData['verification_uri'] as String;
    final interval = (deviceData['interval'] as num?)?.toInt() ?? 5;

    await _storage.write(key: _keyDeviceCode, value: deviceCode);

    // Step 2: Open browser
    final url = Uri.parse(verificationUri);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }

    // Step 3: Poll for token
    final pollMs = Duration(seconds: interval);
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollMs);

      try {
        final tokenResp = await _dio.post(
          _githubTokenUrl,
          data: {
            'client_id': clientId,
            'device_code': deviceCode,
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          },
          options: Options(
            headers: {
              'Accept': 'application/json',
              'User-Agent': 'jxcode',
            },
            contentType: 'application/json',
          ),
        );

        final tokenData = tokenResp.data as Map<String, dynamic>;

        if (tokenData.containsKey('access_token')) {
          final token = tokenData['access_token'] as String;
          await _storage.write(key: _keyGithubToken, value: token);
          await _storage.delete(key: _keyDeviceCode);
          return token;
        }

        final error = tokenData['error'] as String?;
        if (error == 'authorization_pending') {
          continue; // User hasn't acted yet.
        }
        if (error == 'slow_down') {
          await Future.delayed(const Duration(seconds: 5));
          continue;
        }
        if (error == 'expired_token' || error == 'access_denied') {
          throw AuthException(error!);
        }
      } on DioException catch (e) {
        // Transient — retry on the next poll cycle.
        if (e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout) {
          continue;
        }
        rethrow;
      }
    }

    throw AuthException('GitHub OAuth device flow timed out after '
        '${timeout.inMinutes} minutes');
  }

  /// Returns the stored GitHub access token, or `null` if not logged in.
  Future<String?> getToken() => _storage.read(key: _keyGithubToken);

  /// Returns `true` if a GitHub access token is stored.
  Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }

  /// Returns the authenticated GitHub username (requires a valid token).
  Future<String?> getGitHubUsername() async {
    final token = await getToken();
    if (token == null || token.isEmpty) return null;

    try {
      final resp = await _dio.get(
        _githubUserUrl,
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
            'User-Agent': 'jxcode',
          },
        ),
      );
      return (resp.data as Map<String, dynamic>)['login'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Removes the stored GitHub token.
  Future<void> logout() async {
    await _storage.delete(key: _keyGithubToken);
    await _storage.delete(key: _keyDeviceCode);
  }

  // ---------------------------------------------------------------------------
  // Provider API keys
  // ---------------------------------------------------------------------------

  /// Anthropic API key for the Claude CLI proxy.
  Future<String?> getAnthropicApiKey() =>
      _storage.read(key: _keyAnthropicKey);

  Future<void> setAnthropicApiKey(String key) =>
      _storage.write(key: _keyAnthropicKey, value: key);

  /// OpenAI API key (used by proxy fallback).
  Future<String?> getOpenaiApiKey() =>
      _storage.read(key: _keyOpenaiKey);

  Future<void> setOpenaiApiKey(String key) =>
      _storage.write(key: _keyOpenaiKey, value: key);

  /// Google / Gemini API key.
  Future<String?> getGoogleApiKey() =>
      _storage.read(key: _keyGoogleKey);

  Future<void> setGoogleApiKey(String key) =>
      _storage.write(key: _keyGoogleKey, value: key);

  /// Custom provider API key.
  Future<String?> getCustomApiKey() =>
      _storage.read(key: _keyCustomKey);

  Future<void> setCustomApiKey(String key) =>
      _storage.write(key: _keyCustomKey, value: key);

  /// Returns a map of every stored provider key (skip nulls / empties).
  Future<Map<String, String>> getAllApiKeys() async {
    final keys = <String, String>{};
    final anthropic = await getAnthropicApiKey();
    if (anthropic != null && anthropic.isNotEmpty) keys['anthropic'] = anthropic;
    final openai = await getOpenaiApiKey();
    if (openai != null && openai.isNotEmpty) keys['openai'] = openai;
    final google = await getGoogleApiKey();
    if (google != null && google.isNotEmpty) keys['google'] = google;
    final custom = await getCustomApiKey();
    if (custom != null && custom.isNotEmpty) keys['custom'] = custom;
    return keys;
  }

  /// Clears all stored secrets.
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => 'AuthException: $message';
}
