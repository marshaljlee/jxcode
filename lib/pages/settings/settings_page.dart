import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../blocs/permission/permission_bloc.dart';
import '../../blocs/permission/permission_event.dart';
import '../../blocs/permission/permission_state.dart';
import '../../blocs/proxy/proxy_bloc.dart';
import '../../blocs/proxy/proxy_state.dart';
import '../../blocs/settings/settings_bloc.dart';
import '../../models/permission_request.dart';
import '../../models/proxy_config.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_indicators.dart';

/// Tabbed settings page with General, Network, Developer, and Account tabs.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: false,
          tabs: const [
            Tab(text: 'General'),
            Tab(text: 'Network'),
            Tab(text: 'Developer'),
            Tab(text: 'Account'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _GeneralTab(),
          _NetworkTab(),
          _DeveloperTab(),
          _AccountTab(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// General Tab
// ---------------------------------------------------------------------------

class _GeneralTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsBloc, SettingsState>(
      builder: (context, settings) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionTitle(title: 'Appearance'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Dark Mode'),
                    subtitle: const Text('Switch between light and dark theme'),
                    value: settings.themeMode == ThemeMode.dark,
                    onChanged: (value) {
                      context.read<SettingsBloc>().setThemeMode(
                        value ? ThemeMode.dark : ThemeMode.light,
                      );
                    },
                    secondary: Icon(
                      settings.themeMode == ThemeMode.dark
                          ? Icons.dark_mode_rounded
                          : Icons.light_mode_rounded,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            _SectionTitle(title: 'Chat'),
            Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    title: const Text('Default Model'),
                    subtitle: Text(settings.defaultModel),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _showModelPicker(context, settings),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    title: const Text('Default Effort'),
                    subtitle: Text(settings.defaultEffort),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _showEffortPicker(context, settings),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            _SectionTitle(title: 'Permissions'),
            Card(
              child: BlocBuilder<PermissionBloc, PermissionState>(
                builder: (context, permState) {
                  return ListTile(
                    title: const Text('Permission Mode'),
                    subtitle: Text(_permissionModeLabel(permState.currentMode)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PermissionBadge(label: permState.currentMode.name),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                    onTap: () => _showPermissionModePicker(context, permState),
                  );
                },
              ),
            ),

            const SizedBox(height: 16),
            _SectionTitle(title: 'Appearance'),
            Card(
              child: ListTile(
                title: const Text('Font Size'),
                subtitle: const Text('Default'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  // Font size picker
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _showModelPicker(BuildContext context, SettingsState settings) {
    const models = ['claude-sonnet-5', 'claude-opus-4-8', 'claude-fable-5', 'claude-haiku-4-5-20251001'];
    _showOptionPicker(
      context,
      title: 'Default Model',
      options: models,
      selected: settings.defaultModel,
      onSelected: (model) => context.read<SettingsBloc>().updateModel(model),
    );
  }

  void _showEffortPicker(BuildContext context, SettingsState settings) {
    const efforts = ['auto', 'low', 'medium', 'high'];
    _showOptionPicker(
      context,
      title: 'Default Effort',
      options: efforts,
      selected: settings.defaultEffort,
      onSelected: (effort) => context.read<SettingsBloc>().updateEffort(effort),
    );
  }

  void _showPermissionModePicker(BuildContext context, PermissionState permState) {
    final modes = PermissionMode.values;
    _showOptionPicker(
      context,
      title: 'Permission Mode',
      options: modes.map((m) => m.name).toList(),
      selected: permState.currentMode.name,
      onSelected: (mode) {
        final parsed = PermissionMode.values.firstWhere((m) => m.name == mode);
        context.read<PermissionBloc>().add(SetPermissionMode(mode: parsed));
      },
    );
  }

  void _showOptionPicker(
    BuildContext context, {
    required String title,
    required List<String> options,
    required String selected,
    required ValueChanged<String> onSelected,
  }) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(title, style: Theme.of(context).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              ...options.map((option) {
                return ListTile(
                  title: Text(option),
                  trailing: option == selected
                      ? Icon(Icons.check_rounded, color: JXCODETheme.terracotta)
                      : null,
                  onTap: () {
                    onSelected(option);
                    Navigator.of(ctx).pop();
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  String _permissionModeLabel(PermissionMode mode) {
    switch (mode) {
      case PermissionMode.safe:
        return 'Auto-allow safe commands only';
      case PermissionMode.moderate:
        return 'Prompt for safe & moderate commands';
      case PermissionMode.high:
        return 'Review all commands';
      case PermissionMode.custom:
        return 'Custom allowlist';
      case PermissionMode.interactive:
        return 'Approve each request';
      case PermissionMode.approveAll:
        return 'Auto-allow everything';
      case PermissionMode.denyAll:
        return 'Auto-deny everything';
      case PermissionMode.session:
        return 'Allow once per session';
    }
  }
}

// ---------------------------------------------------------------------------
// Network Tab
// ---------------------------------------------------------------------------

class _NetworkTab extends StatefulWidget {
  @override
  State<_NetworkTab> createState() => _NetworkTabState();
}

class _NetworkTabState extends State<_NetworkTab> {
  late final TextEditingController _portController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _customHostController;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController();
    _apiKeyController = TextEditingController();
    _customHostController = TextEditingController();
  }

  @override
  void dispose() {
    _portController.dispose();
    _apiKeyController.dispose();
    _customHostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<ProxyBloc, ProxyState>(
      builder: (context, proxyState) {
        _portController.text = proxyState.config.port.toString();
        _apiKeyController.text = proxyState.config.apiKey;
        _customHostController.text = proxyState.config.customHost;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionTitle(title: 'Proxy Status'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    ConnectionDot(
                      isActive: proxyState.status == 'running',
                      latency: proxyState.latency,
                      size: 12,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            proxyState.status == 'running' ? 'Proxy Running' : 'Proxy Stopped',
                            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          if (proxyState.status == 'running')
                            Text(
                              'Port ${proxyState.config.port} · ${proxyState.latency.toStringAsFixed(0)} ms',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: () {
                        if (proxyState.status == 'running') {
                          context.read<ProxyBloc>().stop();
                        } else {
                          context.read<ProxyBloc>().start();
                        }
                      },
                      child: Text(proxyState.status == 'running' ? 'Stop' : 'Start'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),
            _SectionTitle(title: 'Proxy Configuration'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _portController,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        helperText: 'Default: 5255',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<ProxyProvider>(
                      initialValue: proxyState.config.provider,
                      decoration: const InputDecoration(labelText: 'Provider'),
                      items: ProxyProvider.values.map((p) {
                        return DropdownMenuItem(value: p, child: Text(p.displayName));
                      }).toList(),
                      onChanged: (provider) {
                        if (provider == null) return;
                        final updated = proxyState.config.copyWith(provider: provider);
                        context.read<ProxyBloc>().updateConfig(updated);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _customHostController,
                      decoration: const InputDecoration(
                        labelText: 'Custom Host',
                        helperText: 'Override host for custom providers',
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () {
                          final port = int.tryParse(_portController.text) ?? 5255;
                          context.read<ProxyBloc>().updateConfig(
                            proxyState.config.copyWith(
                              port: port,
                              apiKey: _apiKeyController.text,
                              customHost: _customHostController.text,
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Configuration saved'), behavior: SnackBarBehavior.floating),
                          );
                        },
                        child: const Text('Save Configuration'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),
            _SectionTitle(title: 'Environment'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ANTHROPIC_BASE_URL',
                      style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'http://127.0.0.1:${proxyState.config.port}/v1',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'ANTHROPIC_API_KEY',
                      style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _apiKeyController.text.isNotEmpty ? '••••••••' : '(empty)',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Developer Tab
// ---------------------------------------------------------------------------

class _DeveloperTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionTitle(title: 'Advanced'),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Verbose Logging'),
                subtitle: const Text('Enable detailed diagnostic output'),
                value: false,
                onChanged: (_) {},
                secondary: const Icon(Icons.bug_report_outlined),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                title: const Text('Developer Mode'),
                subtitle: const Text('Show advanced options'),
                value: false,
                onChanged: (_) {},
                secondary: const Icon(Icons.developer_mode_rounded),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),
        _SectionTitle(title: 'Commands'),
        Card(
          child: ListTile(
            title: const Text('Custom Commands'),
            subtitle: const Text('Configure slash commands and shortcuts'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Command configuration coming soon'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 16),
        _SectionTitle(title: 'Diagnostics'),
        Card(
          child: Column(
            children: [
              ListTile(
                title: const Text('Proxy Logs'),
                subtitle: const Text('View recent proxy activity'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _showProxyLogs(context),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                title: const Text('Reset All Settings'),
                subtitle: const Text('Restore default configuration'),
                trailing: Icon(Icons.warning_amber_rounded, color: JXCODETheme.error),
                onTap: () => _confirmReset(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showProxyLogs(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          maxChildSize: 0.8,
          minChildSize: 0.3,
          expand: false,
          builder: (_, scrollController) {
            return SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Proxy Logs', style: Theme.of(context).textTheme.titleMedium),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: BlocBuilder<ProxyBloc, ProxyState>(
                      builder: (context, proxyState) {
                        if (proxyState.logEntries.isEmpty) {
                          return const Center(child: Text('No log entries'));
                        }
                        return ListView.builder(
                          controller: scrollController,
                          itemCount: proxyState.logEntries.length,
                          itemBuilder: (_, i) {
                            final entry = proxyState.logEntries[i];
                            return ListTile(
                              dense: true,
                              title: Text(
                                '${entry['latency']} ms',
                                style: const TextStyle(fontSize: 12),
                              ),
                              subtitle: Text(
                                '${entry['timestamp']}',
                                style: const TextStyle(fontSize: 10),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _confirmReset(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Reset Settings'),
          content: const Text('This will restore all settings to their defaults. This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Settings reset'), behavior: SnackBarBehavior.floating),
                );
              },
              style: FilledButton.styleFrom(backgroundColor: JXCODETheme.error),
              child: const Text('Reset'),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Account Tab
// ---------------------------------------------------------------------------

class _AccountTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionTitle(title: 'Authentication'),
        Card(
          child: ListTile(
            title: const Text('GitHub Account'),
            subtitle: const Text('Not connected'),
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.person_outline_rounded),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('GitHub login flow coming soon'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 16),
        _SectionTitle(title: 'Usage'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'API Usage',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                _usageRow(theme, 'Requests today', '--'),
                const SizedBox(height: 4),
                _usageRow(theme, 'Tokens used', '--'),
                const SizedBox(height: 4),
                _usageRow(theme, 'Estimated cost', '--'),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      // Launch usage dashboard
                    },
                    child: const Text('View Details'),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 24),
        Center(
          child: Text(
            'JXCODE v2.0.0',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _usageRow(ThemeData theme, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        Text(value, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
