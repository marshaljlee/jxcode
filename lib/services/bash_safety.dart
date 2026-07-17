/// Whitelist-based command validator for the Claude CLI tool-use hook.
///
/// [isCommandSafe] inspects a raw command string and returns `true` when
/// the command is read-only and matches the approved whitelist. Any
/// write, mutate, publish, or destructive operation is blocked.
///
/// Blocking is layered:
///   1. Base command must be on the read-only whitelist.
///   2. Subcommand probes detect write-equivalent subcommands.
///   3. Pipe and redirection patterns are blacklisted.
///   4. Dangerous flags / arguments are detected.
class BashSafety {
  BashSafety._();

  /// Commands considered read-only by base name.
  static const _readOnlyCommands = <String>{
    'ls', 'cat', 'less', 'more', 'head', 'tail',
    'grep', 'egrep', 'fgrep', 'rg', 'ripgrep', 'ag', 'ack',
    'find', 'locate', 'mlocate',
    'pwd', 'echo', 'printf',
    'which', 'type', 'whereis', 'command', 'realpath', 'readlink',
    'wc', 'sort', 'uniq', 'cut', 'tr', 'fold', 'fmt', 'nl', 'od', 'tac', 'rev',
    'diff', 'cmp', 'comm', 'patch', 'sdiff',
    'file', 'stat', 'du', 'df', 'mount',
    'date', 'cal', 'time', 'uptime', 'who', 'w', 'whoami', 'id', 'groups',
    'uname', 'hostname', 'arch', 'env', 'printenv',
    'ps', 'top', 'htop', 'jobs',
    'lsof', 'netstat', 'ss', 'ifconfig', 'ip', 'dig', 'nslookup', 'host',
    'curl', 'wget', 'jq', 'yq',
    'tree', 'basename', 'dirname', 'xargs',
    'man', 'apropos', 'whatis', 'help',
    'hexdump', 'xxd', 'strings', 'base64', 'md5sum', 'sha256sum',
    'tput', 'stty', 'ulimit',
    'mkfile',
  };

  /// Base commands that are NEVER safe regardless of arguments.
  static const _alwaysBlocked = <String>{
    'rm', 'mv', 'cp', 'dd', 'mkfs', 'fdisk', 'parted',
    'sudo', 'doas', 'su', 'chown', 'chmod', 'chattr',
    'kill', 'pkill', 'killall',
    'reboot', 'shutdown', 'halt', 'poweroff', 'init',
    'passwd', 'adduser', 'useradd', 'deluser', 'userdel', 'usermod',
    'dpkg', 'apt', 'apt-get', 'apk', 'pacman', 'yum', 'dnf', 'brew', 'port',
    'pip', 'pip3', 'npm', 'yarn', 'pnpm', 'npx',
    'cargo', 'gem', 'bundle', 'composer',
    'docker', 'podman', 'nerdctl', 'kubectl', 'helm', 'minikube',
    'terraform', 'pulumi', 'tofu',
    'git',
    'claude',
  };

  /// Write-subcommands for git (all blocked).
  static const _gitWriteSubcommands = <String>{
    'add', 'commit', 'push', 'pull', 'merge', 'rebase', 'reset',
    'branch', 'checkout', 'switch', 'restore', 'stash', 'tag',
    'rm', 'mv', 'cherry-pick', 'revert', 'archive', 'gc',
    'submodule', 'worktree', 'update-ref', 'notes', 'config',
    'remote', 'fetch', 'init',
  };

  /// Write-subcommands for claude (all blocked).
  static const _claudeWriteSubcommands = <String>{
    'push', 'commit', 'init', 'update', 'upgrade',
    'config', 'login', 'logout',
  };

  /// Write-subcommands for npm / yarn / pnpm.
  static const _npmWriteSubcommands = <String>{
    'install', 'add', 'update', 'remove', 'uninstall',
    'publish', 'unpublish', 'deprecate', 'owner',
    'config', 'set', 'delete', 'init',
    'run', 'exec', 'link', 'prune', 'rebuild',
  };

  /// Pipe-to commands that are never safe (destructive receivers).
  static final _pipeBlacklist = RegExp(
    r'\|\s*('
    r'(sudo|doas|su|sh|bash|zsh|fish)'
    r'|(rm|mv|cp|dd)'
    r'|(tee|a?sh|install)'
    r')',
    caseSensitive: false,
  );

  /// File redirection operators that indicate a write.
  static final _redirectionPattern = RegExp(
    r'(?:^|[|;&])\s*[^|&;<>]*[>]\s*[/\w.\-$~]',
    caseSensitive: false,
  );

  /// Dangerous argument patterns (force-delete, recursive via wildcard,
  /// dangerously-allowed tools).
  static final _dangerousArgs = RegExp(
    r'\s(-rf\b|--recursive\s+-f\b|-f\s+--recursive\b|'
    r'--force\b|--delete\b|--no-preserve-root\b|'
    r'--allow-dangerous\b)',
    caseSensitive: false,
  );

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns `true` if [command] is safe to execute (read-only,
  /// whitelisted, no destructive flags).
  static bool isCommandSafe(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return true;

    // Block via composite patterns first.
    if (_pipeBlacklist.hasMatch(trimmed)) return false;
    if (_redirectionPattern.hasMatch(trimmed)) return false;

    // Extract the base command (first word, handle path prefix).
    final baseCmd = _extractBaseCommand(trimmed);
    if (baseCmd == null) return false;

    // Block always-dangerous commands outright.
    if (_alwaysBlocked.contains(baseCmd)) return false;

    // If it's on the read-only whitelist, allow it immediately.
    if (_readOnlyCommands.contains(baseCmd)) {
      // Still check for dangerous args.
      if (_dangerousArgs.hasMatch(trimmed)) return false;
      return true;
    }

    // If it's a git command, check for write subcommands.
    if (baseCmd == 'git') {
      final sub = _extractSubcommand(trimmed);
      if (sub == null) return false; // bare git is unsafe.
      final safe = !_gitWriteSubcommands.contains(sub);
      if (!safe) return false;
      // git read-only commands (log, diff, show, status, …) are safe.
      if (_dangerousArgs.hasMatch(trimmed)) return false;
      return true;
    }

    // If it's a claude command, check subcommands.
    if (baseCmd == 'claude') {
      final sub = _extractSubcommand(trimmed);
      if (sub == null) return false; // bare claude is ambiguous.
      return !_claudeWriteSubcommands.contains(sub);
    }

    // npm / yarn / pnpm.
    if (_isNpmFamily(baseCmd)) {
      final sub = _extractSubcommand(trimmed);
      if (sub == null) return false;
      return !_npmWriteSubcommands.contains(sub);
    }

    // Unknown command — not on either whitelist or blocklist. Risk:
    // it could be anything, so default deny.
    return false;
  }

  /// Returns the reason a command was blocked (for UI display), or
  /// `null` if the command is safe.
  static String? blockedReason(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return null;

    if (_pipeBlacklist.hasMatch(trimmed)) {
      return 'Piped to a destructive command';
    }
    if (_redirectionPattern.hasMatch(trimmed)) {
      return 'Contains file redirection operator (>)';
    }
    if (_dangerousArgs.hasMatch(trimmed)) {
      return 'Contains dangerous flags (--force, -rf, etc.)';
    }

    final baseCmd = _extractBaseCommand(trimmed);
    if (baseCmd == null) return 'Could not parse command';
    if (_alwaysBlocked.contains(baseCmd)) {
      return '"$baseCmd" is not permitted';
    }

    final sub = _extractSubcommand(trimmed);

    if (baseCmd == 'git' && sub != null && _gitWriteSubcommands.contains(sub)) {
      return 'git $sub is a write operation';
    }
    if (baseCmd == 'claude' && sub != null &&
        _claudeWriteSubcommands.contains(sub)) {
      return 'claude $sub is a write operation';
    }
    if (_isNpmFamily(baseCmd) && sub != null &&
        _npmWriteSubcommands.contains(sub)) {
      return '$baseCmd $sub is a write operation';
    }

    if (!_readOnlyCommands.contains(baseCmd) &&
        !_alwaysBlocked.contains(baseCmd) &&
        baseCmd != 'git' &&
        baseCmd != 'claude' &&
        !_isNpmFamily(baseCmd)) {
      return '"$baseCmd" is not on the read-only whitelist';
    }

    return null; // Safe.
  }

  // ---------------------------------------------------------------------------
  // Parsing helpers
  // ---------------------------------------------------------------------------

  /// Extracts the base command from a command string, stripping any
  /// leading path or interpreter.
  ///
  /// Examples:
  ///   'ls -la'        → 'ls'
  ///   '/usr/bin/find' → 'find'
  ///   'git log --oneline' → 'git'
  static String? _extractBaseCommand(String command) {
    final trimmed = command.trimLeft();
    if (trimmed.isEmpty) return null;

    // Skip leading && / || / ; / |
    final clean = trimmed
        .split(RegExp(r'[;&|]'))
        .firstWhere(
          (s) => s.trim().isNotEmpty,
          orElse: () => '',
        )
        .trim();

    if (clean.isEmpty) return null;

    // Take the first token.
    final firstToken = clean.split(RegExp(r'\s+')).first;
    return firstToken.contains('/')
        ? firstToken.split('/').last
        : firstToken;
  }

  /// Extracts the first subcommand (second token) from a command string,
  /// ignoring leading flags.
  static String? _extractSubcommand(String command) {
    // Split on whitespace and skip command name + any leading flags.
    final parts = command.split(RegExp(r'\s+'));
    if (parts.length < 2) return null;
    for (int i = 1; i < parts.length; i++) {
      final part = parts[i];
      if (part.startsWith('-')) continue;
      return part;
    }
    return null;
  }

  static bool _isNpmFamily(String cmd) =>
      cmd == 'npm' || cmd == 'yarn' || cmd == 'pnpm' || cmd == 'npx';
}
