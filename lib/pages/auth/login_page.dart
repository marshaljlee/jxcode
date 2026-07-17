import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// GitHub OAuth login page using Device Flow.
///
/// Displays a QR code and device code, then polls for token completion.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _isPolling = false;
  bool _isComplete = false;
  String? _userCode;
  String? _verificationUri;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startDeviceFlow();
  }

  Future<void> _startDeviceFlow() async {
    setState(() {
      _isPolling = true;
      _error = null;
    });

    // Simulate device flow initiation — in production, call
    // GitHubService.startDeviceFlow() and then poll.
    await Future.delayed(const Duration(milliseconds: 800));

    if (mounted) {
      setState(() {
        _userCode = 'ABCD-1234';
        _verificationUri = 'https://github.com/login/device';
      });
    }

    // Simulate polling
    _simulatePolling();
  }

  Future<void> _simulatePolling() async {
    // In production, poll GitHubService.pollForToken() every 5 seconds.
    await Future.delayed(const Duration(seconds: 3));

    if (mounted) {
      setState(() {
        _isPolling = false;
        _isComplete = true;
      });
    }
  }

  void _cancel() {
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _retry() {
    setState(() {
      _isComplete = false;
      _error = null;
    });
    _startDeviceFlow();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to GitHub'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _cancel,
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: _buildContent(theme, isDark),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme, bool isDark) {
    if (_error != null) {
      return _buildErrorState(theme);
    }

    if (_isComplete) {
      return _buildCompleteState(theme);
    }

    return _buildDeviceFlowState(theme, isDark);
  }

  Widget _buildDeviceFlowState(ThemeData theme, bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // QR code placeholder
        Container(
          width: 200,
          height: 200,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.qr_code_rounded,
                  size: 80,
                  color: Colors.black.withValues(alpha: 0.8),
                ),
                const SizedBox(height: 8),
                Text(
                  'Scan to authenticate',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.black.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 24),

        // Device code
        Text(
          'Enter this code on GitHub',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? theme.colorScheme.surfaceContainerHighest : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Text(
            _userCode ?? '------',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
              color: JXCODETheme.terracotta,
            ),
          ),
        ),

        const SizedBox(height: 12),
        Text(
          _verificationUri ?? '',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),

        const SizedBox(height: 24),

        // Polling indicator
        if (_isPolling)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Waiting for authentication...',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),

        const SizedBox(height: 24),

        // Cancel button
        OutlinedButton(
          onPressed: _cancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildCompleteState(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: JXCODETheme.success.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.check_rounded,
            size: 36,
            color: JXCODETheme.success,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Authentication Complete',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Your GitHub account has been linked successfully.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _buildErrorState(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: JXCODETheme.error.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.error_outline_rounded,
            size: 36,
            color: JXCODETheme.error,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Authentication Failed',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          _error ?? 'An error occurred during authentication.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton(
              onPressed: _cancel,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _retry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ],
    );
  }
}
