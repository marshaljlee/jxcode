import Foundation

/// Generates the sandbox's zsh init files.
///
/// These exist because inheriting the host shell config would defeat the
/// sandbox. Three specific hazards are handled here:
///
/// 1. **`/etc/zprofile` runs `/usr/libexec/path_helper`**, which rebuilds
///    `PATH` from `/etc/paths`. On macOS that list starts with
///    `/usr/local/bin`, so a `PATH` set only in `.zshenv` gets host entries
///    added back. We therefore re-assert `PATH` in `.zshenv`, `.zprofile` *and*
///    `.zshrc` — and the re-assert both **prepends sandbox entries and strips
///    known host tool directories**, because prepending alone leaves the host
///    entries reachable further down the list.
///
/// 2. **`ZDOTDIR`** is redirected here, so `~/.zshrc` and `~/.zprofile` on the
///    host are never read. A user who wants their own config sources it
///    explicitly through `.zshrc.user`, which is a sandbox-local copy.
///
/// 3. **A user's own rc file can rewrite `PATH`.** Because the re-assert runs
///    *after* `.zshrc.user` is sourced, that cannot undo the sandbox either.
public enum ShellInit {

    /// Write all init files. Overwrites generated files, leaves `.user` files alone.
    public static func install(
        paths: SandboxPaths,
        realHome: String = NSHomeDirectory(),
        includeHostLocalBin: Bool = false
    ) throws {
        try paths.createDirectories()
        let fm = FileManager.default

        try write(fm, paths.zshDir.appendingPathComponent(".zshenv"),
                  zshenv(paths: paths, realHome: realHome, includeHostLocalBin: includeHostLocalBin))
        try write(fm, paths.zshDir.appendingPathComponent(".zprofile"),
                  zprofile(paths: paths))
        try write(fm, paths.zshDir.appendingPathComponent(".zshrc"),
                  zshrc(paths: paths))
        try write(fm, paths.gitConfig, gitconfig(paths: paths, realHome: realHome))

        // Seed a global CLAUDE.md so the isolation is visible and testable.
        // Claude Code reads $CLAUDE_CONFIG_DIR/CLAUDE.md as its global memory.
        let claudeMemory = paths.claudeConfig.appendingPathComponent("CLAUDE.md")
        if !fm.fileExists(atPath: claudeMemory.path) {
            try write(fm, claudeMemory, claudeMemorySeed(paths: paths, realHome: realHome))
        }
    }

    private static func write(_ fm: FileManager, _ url: URL, _ contents: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Absolute paths baked in as single-quoted literals.
    ///
    /// Generated rather than derived from `$JXCODE_ENV_ROOT` at runtime, so a
    /// path containing spaces (Application Support does) cannot break array
    /// expansion.
    private static func preludeArray(paths: SandboxPaths) -> String {
        // This list and `SandboxEnvironment.buildPath()` must agree, and they
        // are written out separately because the shell script has to be
        // generated text rather than built at runtime. They are not identical
        // — the base system directories are absent here because `_jx_assert_path`
        // preserves whatever the host already had, while `buildPath()` states
        // them explicitly — but every *sandbox* entry must appear in both, or a
        // login shell and a GUI-launched tab disagree about `PATH` order.
        //
        // `ShellInitTests` asserts that the shared bin reaches both, which is
        // the case most likely to be forgotten: it was added after this list
        // was written.
        let entries = [
            paths.bin.path,
            paths.sharedBin.path,
            paths.npmPrefix.appendingPathComponent("bin").path,
            paths.localBin.path,
            paths.cargoHome.appendingPathComponent("bin").path,
            paths.brewPrefix.appendingPathComponent("bin").path,
            paths.brewPrefix.appendingPathComponent("sbin").path,
            paths.goPath.appendingPathComponent("bin").path,
            paths.gemHome.appendingPathComponent("bin").path,
            paths.bunInstall.appendingPathComponent("bin").path,
        ]
        let lines = entries.map { "  '\($0)'" }.joined(separator: "\n")
        return "_JX_PRE=(\n\(lines)\n)"
    }

    /// Host tool directories to strip from `PATH` outright.
    ///
    /// `path_helper` adds these back on every login shell, and a user's rc file
    /// can add them too. Prepending the sandbox entries is not enough — a host
    /// binary sitting later in `PATH` is still executable, and a host-wide
    /// `claude` there would write to the real `~/.claude`.
    private static func denyArray(includeHostLocalBin: Bool) -> String {
        var entries = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/opt/homebrew/Cellar",
            "/usr/local/Homebrew/bin",
            "/usr/local/Homebrew/sbin",
        ]
        // `/usr/local/bin` is a judgement call: it is where a host Homebrew
        // usually lives, but also where some vendors install. Excluded unless
        // the caller explicitly opts in.
        if !includeHostLocalBin {
            entries.append("/usr/local/bin")
            entries.append("/usr/local/sbin")
        }
        let lines = entries.map { "  '\($0)'" }.joined(separator: "\n")
        return "_JX_DENY=(\n\(lines)\n)"
    }

    /// Re-assert `PATH`. Idempotent, so it is safe to call repeatedly.
    ///
    /// Drops every entry that is either a sandbox entry (re-added at the front)
    /// or a denied host tool directory, then prepends the sandbox entries.
    /// Relies on zsh's `$path` being tied to `$PATH`.
    private static let assertPathFunction = #"""
# Re-assert the sandbox PATH: strip sandbox and host-tool entries, then
# prepend the sandbox entries. Safe to call more than once.
_jx_assert_path() {
  emulate -L zsh
  setopt local_options no_nomatch 2>/dev/null
  [[ -z "${path[*]}" ]] && path=(${=PATH})

  local -a blocked
  blocked=( ${_JX_PRE[@]} ${_JX_DENY[@]} )

  # The one directory that cannot be enumerated. ~/.local/bin, ~/.cargo/bin,
  # ~/.bun/bin, ~/.volta/bin, ~/.asdf/shims, ~/Library/pnpm and every nvm
  # version directory all hold host binaries, and a new runtime appears every
  # year — so the rule is the directory, not a list of names.
  #
  # `:A` resolves symlinks first: on macOS the same place is reachable as both
  # /Users/name and /System/Volumes/Data/Users/name.
  #
  # The sandbox normally lives *under* the real home, so this strips the
  # sandbox's own entries too. They are re-prepended from $_JX_PRE below, which
  # is what makes the rule safe rather than self-defeating.
  local real="${JXCODE_REAL_HOME:A}"

  local -a keep
  local entry candidate skip
  keep=()
  for entry in ${path[@]}; do
    if [[ -n "$real" ]]; then
      local resolved="${entry:A}"
      if [[ "$resolved" == "$real" || "$resolved" == "$real"/* ]]; then
        continue
      fi
    fi
    skip=0
    for candidate in ${blocked[@]}; do
      if [[ "$entry" == "$candidate" ]]; then
        skip=1
        break
      fi
    done
    (( skip )) || keep+=("$entry")
  done

  path=( ${_JX_PRE[@]} ${keep[@]} )
  export PATH
}
"""#

    // MARK: - Files

    private static func zshenv(
        paths: SandboxPaths,
        realHome: String,
        includeHostLocalBin: Bool
    ) -> String {
        #"""
        # JXCode — sandbox shell init.
        # GENERATED FILE. Edits are overwritten the next time the sandbox starts.
        #
        # Sourced for every zsh. Sets identity, then re-asserts PATH.

        export JXCODE_SANDBOX=1
        export JXCODE_ENV_ROOT='\#(paths.envRoot.path)'
        export JXCODE_HOME='\#(paths.home.path)'
        export JXCODE_REAL_HOME='\#(realHome)'

        export HOME="$JXCODE_HOME"
        export ZDOTDIR='\#(paths.zshDir.path)'
        export TMPDIR='\#(paths.tmp.path)'
        export XDG_CONFIG_HOME='\#(paths.xdgConfig.path)'
        export XDG_DATA_HOME='\#(paths.xdgData.path)'
        export XDG_STATE_HOME='\#(paths.xdgState.path)'
        export XDG_CACHE_HOME='\#(paths.xdgCache.path)'

        \#(preludeArray(paths: paths))

        \#(denyArray(includeHostLocalBin: includeHostLocalBin))

        \#(assertPathFunction)

        _jx_assert_path
        """#
    }

    private static func zprofile(paths: SandboxPaths) -> String {
        #"""
        # JXCode — sandbox login shell init.
        # GENERATED FILE. Edits are overwritten.
        #
        # Runs AFTER /etc/zprofile, which is where macOS path_helper rebuilds
        # PATH and re-adds /usr/local/bin. Re-asserting here is what removes it
        # again — this file is the reason the sandbox PATH holds.

        [[ -f "$ZDOTDIR/.zprofile.user" ]] && source "$ZDOTDIR/.zprofile.user"

        _jx_assert_path
        """#
    }

    private static func zshrc(paths: SandboxPaths) -> String {
        #"""
        # JXCode — sandbox interactive shell init.
        # GENERATED FILE. Edits are overwritten.
        #
        # To use your own zshrc, put it at:
        #   \#(paths.zshDir.path)/.zshrc.user
        # It is sourced below, inside the sandbox. The PATH re-assert runs after
        # it, so your config cannot accidentally widen the sandbox.

        HISTFILE="$JXCODE_HOME/.zsh_history"
        HISTSIZE=100000
        SAVEHIST=100000
        setopt HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS SHARE_HISTORY 2>/dev/null

        [[ -f "$ZDOTDIR/.zshrc.user" ]] && source "$ZDOTDIR/.zshrc.user"

        _jx_assert_path

        # Prompt marks every line as sandboxed so there is never any doubt.
        PROMPT='%F{214}[jx]%f %F{244}%~%f %# '

        # --- sandbox helpers -------------------------------------------------

        # Show where this shell thinks everything lives.
        jx-env() {
          print -P '%F{214}JXCode sandbox%f'
          print "  HOME               $HOME"
          print "  npm prefix         $npm_config_prefix"
          print "  CLAUDE_CONFIG_DIR  $CLAUDE_CONFIG_DIR"
          print "  CODEX_HOME         $CODEX_HOME"
          print "  brew prefix        $HOMEBREW_PREFIX"
          print "  workspace          ${JXCODE_WORKSPACE:-<none>}"
          print "  real home          $JXCODE_REAL_HOME"
        }

        # jx-where claude node python3
        # Flags anything resolving outside the sandbox in red.
        jx-where() {
          local t r
          for t in "$@"; do
            r="$(whence -p "$t" 2>/dev/null)"
            if [[ -z "$r" ]]; then
              print "  $t: not installed"
            elif [[ "$r" == "$JXCODE_ENV_ROOT"* ]]; then
              print -P "  $t: %F{green}$r%f  (sandbox)"
            else
              print -P "  $t: %F{red}$r%f  (OUTSIDE sandbox)%f"
            fi
          done
        }

        # Escape hatch. Clearly labelled, deliberately manual.
        jx-real() {
          print -P "%F{196}leaving the sandbox%f -> $JXCODE_REAL_HOME"
          cd "$JXCODE_REAL_HOME"
        }

        jx-sandbox() { cd "$JXCODE_HOME" }

        print -P "%F{244}JXCode sandbox · %F{214}jx-where%f%F{244} to audit binaries%f"
        """#
    }

    /// Git needs identity. We keep the *config file* inside the sandbox but
    /// read the host one for identity and aliases, so commits work without
    /// copying credentials into the sandbox.
    private static func gitconfig(paths: SandboxPaths, realHome: String) -> String {
        """
        # JXCode — sandbox git config. GENERATED FILE.
        #
        # Reads the host config for identity and aliases (read-only, via
        # include). Anything this config writes — credentials, hooks, new
        # aliases — lands inside the sandbox.

        [include]
        \tpath = \(realHome)/.gitconfig

        [safe]
        \tdirectory = *
        """
    }

    private static func claudeMemorySeed(paths: SandboxPaths, realHome: String) -> String {
        """
        # Global memory — JXCode sandbox

        This file is Claude Code's *global* memory, and it lives inside the
        JXCode sandbox at:

            \(paths.claudeConfig.path)/CLAUDE.md

        It is not \(realHome)/.claude/CLAUDE.md. Anything you write here applies
        only to agents launched from the JXCode app, and the host file is never
        read or modified.

        ## Environment

        - Sandbox root: `\(paths.root.path)`
        - Global installs land in `\(paths.npmPrefix.path)`
        - Nothing here is on the host `PATH`

        ## Notes

        Add project-independent instructions below this line.
        """
    }
}
