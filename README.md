# JXCode

A macOS agent workspace manager in the shape of [Origami](https://tryorigami.app),
but with one deliberate inversion: **Origami gives your existing toolchain a
shared home; JXCode gives it a private one.**

Every agent it launches runs inside a sandbox the app owns. Installing a CLI
inside JXCode keeps it inside JXCode, and a global `CLAUDE.md` written there is
not the `CLAUDE.md` in your real home directory.

This repository implements all three pillars of the design:

1. **Isolated runtime** — a private `$HOME`, private package prefixes, and a
   deny-listed `PATH`. Built and verified.
2. **Registered backends and a local router** — point every agent at one backend
   of your choosing, with Anthropic ⇄ OpenAI translation. Built and verified.
3. **Local GGUF** — read the model's own metadata, pair it with the right vision
   projector, and derive the `llama-server` invocation from the hardware that is
   actually present. Built and verified against real models and a real binary.

---

## The isolation model

Three mechanisms, in order of how much work they do:

### 1. A private `$HOME`

Every process is spawned with `HOME` pointed at the sandbox. This is the
load-bearing mechanism, because a large class of tools — **oh-my-pi (`~/.omp`)
and Jules (`~/.jules`) among them** — document no config-directory variable at
all. Their config root is a fixed path under `~`, so `$HOME` is the only lever
that exists.

`XDG_*`, `TMPDIR`, `ZDOTDIR` and every package-manager prefix move with it:
`npm_config_prefix`, `HOMEBREW_PREFIX`/`CELLAR`/`REPOSITORY`, `CARGO_HOME`,
`GOPATH`, `GEM_HOME`, `BUN_INSTALL`, `PIP_CACHE_DIR`, `PYTHONUSERBASE`.

### 2. Explicit config roots for the agents that have them

`CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `GEMINI_CONFIG_DIR` are set explicitly
rather than left to default. This matters more than it looks — see
[the `getpwuid` caveat](#caveat-getpwuid-ignores-home).

### 3. A rebuilt `PATH`, with a deny-list

The host `PATH` is **not** inherited; it is rebuilt from scratch, and
`/opt/homebrew/*` and `/usr/local/*` are excluded. That exclusion is enforced in
two places, because `PATH` is not set once and forgotten:

- `SandboxEnvironment.buildPath()` constructs it correctly to begin with.
- The generated `.zshenv` / `.zprofile` / `.zshrc` **re-assert it**, stripping
  denied directories rather than merely prepending sandbox ones.

The second half is not optional. macOS `/etc/zprofile` runs
`/usr/libexec/path_helper`, which rebuilds `PATH` from `/etc/paths` — and that
list begins with `/usr/local/bin`. A `PATH` set only in `.zshenv` gets host
entries added back, and a host-wide `claude` sitting later in `PATH` is still
executable and would write to your real `~/.claude`. There is a test for exactly
this (`testPathSurvivesPathHelper`), and it failed until the deny-list existed.

---

## Layout

```
~/Library/Application Support/JXCode/        (override with JXCODE_ROOT)
├── env/
│   ├── home/          $HOME            ← .claude, .codex, .omp, .jules, .bun …
│   ├── bin/           PATH[0]          ← the node/npm/npx shims land here
│   ├── npm/           npm_config_prefix  ← `npm i -g` lands here
│   ├── brew/          HOMEBREW_PREFIX
│   ├── zsh/           ZDOTDIR            ← generated init
│   └── tmp/           TMPDIR
├── workspaces/        project directories
├── shared/            the app-wide collection — see below
│   ├── skills/        <id>/SKILL.md, one directory per skill
│   ├── connectors/    <id>/connector.json
│   ├── automations/   <id>.json
│   ├── bin/           shared connector installs + tool links, on every agent's PATH
│   └── mcp.json       the record of what JXCode wrote into whose config
├── state/             workspaces.json, agents.json, providers.json
└── logs/              router.log, llama-server-<model>.log
```

`PATH[0]` is not decoration. It is where `NodeToolchain` writes the `node`,
`npm` and `npx` shims that make an install possible at all — see
[the Node toolchain](#the-node-toolchain-is-borrowed-not-copied).

---

## Build and run

Requires macOS 14+ and a Swift 6 toolchain.

```bash
# Unit tests + dynamic isolation proof
swift test --disable-sandbox

# End-to-end: prove binding and unbinding are inverse operations
./scripts/verify_collection.sh

# Build a double-clickable bundle
./scripts/build-app.sh
open .build/JXCode.app
```

`--disable-sandbox` is needed when the build itself runs inside a sandbox,
because SwiftPM invokes `sandbox-exec` to compile its manifest and that nesting
is refused. It is harmless otherwise.

### The CLI harness

`jxcode` exercises the same `Sandbox` the GUI does, so a passing `jxcode prove`
is evidence about the app rather than about a parallel code path.

```bash
swift build --disable-sandbox
./.build/debug/jxcode doctor          # audit the sandbox for leaks
./.build/debug/jxcode prove           # spawn processes, verify where they land
./.build/debug/jxcode env             # resolved environment
./.build/debug/jxcode paths           # directory layout
./.build/debug/jxcode import --dry-run
./.build/debug/jxcode run node --version
./.build/debug/jxcode pty claude      # interactive, through the pty layer

# Pillar 02
./.build/debug/jxcode models http://127.0.0.1:8080 --fetch
./.build/debug/jxcode provider-add local http://127.0.0.1:8080 --fetch
./.build/debug/jxcode route --model qwen3-coder   # serve every agent
./.build/debug/jxcode bind --model qwen3-coder    # write agent configs
./.build/debug/jxcode translate request.json      # inspect a translation

# Pillar 03
./.build/debug/jxcode scan --models ~/Models           # find GGUF files, pair projectors
./.build/debug/jxcode model-info Ornith.gguf --all-keys # what the metadata actually says
./.build/debug/jxcode llama-plan Ornith.gguf --memory safe --cache balanced
./.build/debug/jxcode runtime                          # where llama-server was found, or why not
./.build/debug/jxcode serve Ornith.gguf --register      # load it, and add it as a backend

# Workspaces, agents and git
./.build/debug/jxcode ls                               # every workspace
./.build/debug/jxcode new scratch                      # a fresh directory
./.build/debug/jxcode adopt ~/code/my-project          # or an existing one, in place
./.build/debug/jxcode git                              # branch, dirty state, ahead/behind
./.build/debug/jxcode git --json                       # same, machine-readable
./.build/debug/jxcode agents                           # built-in and custom, installed or not
./.build/debug/jxcode install gemini                   # install one, exactly as a click does
./.build/debug/jxcode agent-add --name "My CLI" --command mycli --args "--flag"

# Router access control
./.build/debug/jxcode auth                             # show the token
./.build/debug/jxcode auth --enable                    # generate one and start enforcing
./.build/debug/jxcode auth --regenerate                # rotate

# The shared collection (app-wide — not reachable through --workspace)
./.build/debug/jxcode shared                           # skills, agents, connectors, automations
./.build/debug/jxcode shared-bind                      # apply the collection to every agent
./.build/debug/jxcode shared-revert                    # take it back out again
./.build/debug/jxcode skill-add --name "Release checklist" --description "…" --file ./CHECKLIST.md
./.build/debug/jxcode connector-add --name filesystem --command npx --args "-y @modelcontextprotocol/server-filesystem"
./.build/debug/jxcode automation-add --name nightly --agent claude --prompt "triage open issues" --cadence daily --hour 9
./.build/debug/jxcode automation-run                   # everything that is due
./.build/debug/jxcode automation-run nightly           # or one by name, schedule or not
```

`jxcode route` prints the environment variables to point an agent at it, and
stays in the foreground with the router log streaming to stdout.

---

## Agents

| Agent | Command | Install (inside the sandbox) | Routed via |
|---|---|---|---|
| Claude Code | `claude` | `npm i -g @anthropic-ai/claude-code` | env + `settings.json` |
| Codex CLI | `codex` | `npm i -g @openai/codex` | env + `config.toml` |
| Gemini CLI | `gemini` | `npm i -g @google/gemini-cli` | environment |
| opencode | `opencode` | `npm i -g opencode-ai` | environment |
| oh-my-pi | `omp` | `npm i -g @oh-my-pi/pi-coding-agent` | environment |
| Google Jules | `jules` | `npm i -g @google/jules` | not applicable |
| Plain shell | `/bin/zsh -l` | — (the system shell) | not applicable |

"Routed via" is the mechanism described under
[binding agents](#binding-agents-to-the-router). Jules is excluded because its
model runs on Google's side — there is nothing to route, and claiming otherwise
would be misleading. `Plain shell` is excluded for the same reason: it is a
login shell inside the sandbox, not an agent.

oh-my-pi is installed through npm rather than its `curl … | sh` installer or its
Homebrew tap: `npm i -g` honours `npm_config_prefix` and therefore lands inside
the sandbox, whereas the shell installer picks its own destination and would
likely escape.

**Jules gets two surfaces.** It is an *async cloud* agent — `jules remote new`
hands work to a remote VM that clones the repo and opens a pull request — so the
CLI dispatches and the dashboard is where you watch. The launcher therefore
offers "Terminal" and "Embedded dashboard", the latter being a `WKWebView` panel
with a persistent data store so sign-in survives relaunch.

> Jules sign-in caveat: Google sometimes refuses OAuth from an embedded web view
> on the grounds that it is not a secure browser. A Safari-like user agent is set
> to reduce the odds and there is an "Open in Safari" escape hatch. If it is
> refused, `jules login` in a terminal tab still works — it opens the real
> browser and stores credentials under the sandbox `$HOME`.

### One click installs, or tells you why it could not

Clicking an agent that is not installed installs it, then opens its tab. The
launcher does not open a shell and type the install command into it — that is
what it used to do, and it could not work: `npm` is not on the sandbox `PATH`,
so the tab filled with `zsh: command not found: npm` and the exit status was
never read. `AgentInstaller` now runs the command itself and reports what
happened.

The install runs in three stages, and a failure names the stage it died in:

| Stage | What it does |
|---|---|
| `toolchain` | Makes sure `node`/`npm`/`npx` resolve inside the sandbox |
| `download` | Runs the agent's install command under the sandbox environment |
| `verify` | Re-resolves the agent's command, so success is proven rather than assumed |

Retries are bounded and classified. Network-shaped failures (`EAI_AGAIN`,
`ENOTFOUND`, `ETIMEDOUT`, HTTP 429) are retried up to three times with a 2s then
6s backoff. Failures that a retry cannot fix — `E404`, `EACCES`, `EPERM`,
`ENOSPC` — abort immediately with a plain-language explanation, because
retrying a package that does not exist just wastes the user's time.

Progress is reported per stage, so the row reads "Preparing…" and then what it
is doing. A second click while an install is in flight is ignored rather than
starting a second `npm i`.

**Agents you add yourself survive a restart.** `AgentRegistry.add` forces
`isBuiltIn = false` rather than trusting the argument. `saveCustom()` persists
only the non-built-in entries, and the `AgentDefinition` initialiser defaults
`isBuiltIn` to `true` — so both the GUI's "Add an agent…" sheet and
`jxcode agent-add` were reporting success, putting the agent in the in-memory
list, and writing `[]` to disk. The agent vanished on the next launch, and
`jxcode install <id>` could not see it at all, because that runs in a fresh
process. `add()` is the only way in, so the rule lives there.

### The Node toolchain is borrowed, not copied

`node` on macOS is a ~52 KB launcher over roughly two dozen Homebrew dylibs, and
`npm` itself is 17 MB of JavaScript. Copying either into the sandbox would be a
large, brittle amount of work that would still not be *correct* — an adopted
`node` that cannot find its dylibs is worse than no `node` at all.

So `NodeToolchain` finds the host runtime and writes three shims —
`node`, `npm`, `npx` — into `~sandbox/env/bin`, which is `PATH[0]` and was
documented as "where JXCode shims are written" long before anything wrote one.
Each shim `exec`s the host binary with the host's own script path. The isolation
that matters still holds: `HOME` and `npm_config_prefix` are the sandbox's, so a
global install lands in `~sandbox/env/npm/bin` and writes its config under the
sandbox home.

This is a seam, and `jxcode doctor` says so out loud rather than hiding it. The
stronger claim — that every executable a tab can reach is sandbox-local — is not
true, and the doctor reports the borrowed runtime as an explicit check.

### Agent icons

Each agent is drawn from its own brand mark, kept as the icon file's actual
layers — paths plus their fills and gradients — rather than a flattened
silhouette, so the marks keep their colour. `AgentIcons` holds the data;
`AgentIconView` renders it.

Two consequences worth knowing:

- **Gradients are resolved against the view box, not the bounding box.** A
  `userSpaceOnUse` gradient in an SVG is anchored to the document's coordinate
  system. Mapping the *bounding box* to the tile instead of the *view box* puts
  the gradient stops in the wrong place, which is subtle enough to look
  deliberate. The mapping lives in one place so it cannot drift.
- **Arc flags are single characters.** In SVG path data, `large-arc-flag` and
  `sweep-flag` are each one character, so a valid path may contain `a4.578
  4.578 0 012.285-.312` — read as three numbers rather than four flags and two
  numbers, the argument list desynchronises and the parser silently returns the
  wrong shape. `SVGPathParser` reads those two arguments character-wise.

An agent with no brand mark of its own falls back to a generic tile. `Plain
shell` is the case that needs one: it is this app's entry for `/bin/zsh`, so
there is no logo to match.

**The app's own chrome is drawn from the same machinery.** Every button, badge
and row glyph comes from [mx-icons](https://github.com/ig-imanish/mx-icons)
rather than from SF Symbols, which is why there is not a single `systemName:`
left anywhere in `Sources/`. Two things made that worth doing:

- **A typo is now a compile error.** `MXIconName` is an enum, so a misspelt
  glyph fails the build instead of silently rendering an empty frame — which is
  what an unknown SF Symbol name does at runtime.
- **The set is vendored, not depended on.** Upstream is 2,242 categories × 6
  variants ≈ 13,000 components, and shipping all of it would add megabytes for
  the 47 the app actually draws. `scripts/generate-mx-icons.py` extracts just
  those, as plain `MXIconDefinition` values, and fails loudly if any icon is
  missing or paints nothing. Re-running it is how the set is refreshed.

Both sets scale through one `IconLayerShape` and one parser (`SVGPathParser`),
so the agent marks and the chrome cannot drift apart. Where an upstream variant
relies on winding order rather than a declared fill rule, the generator records
that explicitly — `circle` is forced to `evenodd` so it renders as a ring.

---

## The dashboard

A workspace with no tabs open shows the launcher: a hero naming the workspace
and its path, a row of four facts about the sandbox, then **two** grids — one
headed `AGENTS` and one headed `TOOLS`.

They are two lists rather than one because the two things are different. An
agent is something JXCode *isolates* — its own `$HOME`, its own config, a
rebuilt `PATH` — and installing one is the point of the app. A tool is something
you already run and want a button for. One merged list would have meant a single
card whose action depended on a flag, and the card would then have had to explain
which kind it was. Split, each card says what it is and offers only the actions
that make sense for it. [Tools](#tools) covers the second grid.

Each card states its own state before you click it: an agent card reads `ready`,
`install`, `installing` or `retry`, where the previous list made you discover
that by clicking. A whole card is one target: click it and the agent is installed
if it is missing and then opened, which is the same contract the old row had, now
legible up front.

---

## Tools

The second grid is for command-line tools you already use. It ships knowing two:

| Tool | What it is |
|---|---|
| **herdr** | Terminal workspace manager for AI coding agents |
| **jcode** | Coding agent on a Claude Max or ChatGPT Pro plan |

The list is hand-written rather than discovered. Enumerating executables would
produce a `PATH` dump, not a dashboard; a tool belongs here once someone has
decided what its binary is called and how it should be started, which is exactly
what `ToolDefinition` records.

### Two places, and the difference is the point

`ToolLocator.locate` looks in the sandbox first, then on the Mac:

- **`.sandbox(path)`** — resolvable on the *sandbox* `PATH`, so an agent could
  run it as it stands. Launchable now.
- **`.host(path)`** — installed on the Mac but outside the sandbox. Usable in
  your own shell, and invisible to an agent.

The two lookups read deliberately different sources. The sandbox one goes through
`ExecutableResolver` against `sandbox.env(workspace:)` — the `PATH` an agent
actually gets. The host one consults a **fixed directory list** (`~/.local/bin`,
`/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`, `~/bin`, `/usr/bin`) and
*not* the app's own `PATH`, which is the trap: a GUI launched from Finder inherits
a minimal `PATH` that omits every one of those, so reading `PATH` would report
"not installed" for a tool the user runs every day.

Both `herdr` and `jcode` are the `.host` case on this machine — they live in
`~/.local/bin`, which is the *user's* home, while `SandboxPaths.localBin` is
`<sandbox>/home/.local/bin`. Same relative path, different home. That is the
isolation working: the sandbox cannot see them, so the card says `Mac only`
rather than pretending otherwise.

### Linking, not copying

`Add to sandbox` makes a host tool reachable inside the sandbox with a symlink
into `shared/bin` — one entry on the `PATH` every agent resolves against, so
linking once makes the tool available to all of them. A symlink rather than a
copy for the same reason `shared/bin` exists: a link follows the original when
the tool updates itself, where a copy goes stale the first time it does.

Both directions are written so they can only touch what JXCode made:

- **`link` refuses to clobber.** `removeItem` does not care what it is deleting,
  so an unconditional replace would silently destroy a real file that happened to
  share the name. Reading `destinationOfSymbolicLink` first tells a link from a
  real file — it succeeds only for a symlink — and a real file gets
  `ToolError.destinationOccupied` instead of being deleted.
- **`unlink` only ever removes a link.** It reads the destination first and
  returns if it is not one, so it cannot delete a user's own install. It is also
  a no-op when there is nothing there, so link → unlink → host-only is stable.

That distinction is what the card's footer is drawn from: `Launch` for a tool
that is in the sandbox, `Add to sandbox` for one that is only on the Mac, and
`Remove from sandbox` **only** when the sandbox copy is a link this app made —
offering to remove an install the user did themselves would be wrong.

---

## The theme

The palette comes from two reference screenshots, one light and one dark, and the
first thing worth saying is that they are **one design in two modes**: the same
warm neutral base, the same amber accent, the same six dot colours. `Theme` is
therefore one palette with two sets of stops rather than two palettes.

It used to be neither. The constants were pinned to a single dark set, so a
light-mode user got a dark app. `Theme` is now built from `adaptive(light:dark:)`,
which resolves through `NSColor(name:dynamicProvider:)` and follows
`appearance.bestMatch(from: [.aqua, .darkAqua])`. The values live in code, next to
the comments that say where each came from, rather than in an asset catalog — a
redesign should not have to re-sample the PNGs to find out what the current amber
is.

What was sampled:

| | Light | Dark |
|---|---|---|
| page | cream `#EAE7E1` | `#141319` |
| card | white `#FEFEFE` | `#191919` |
| accent, as a fill | `#FEB43B` | `#FEB43B` |
| accent, as a foreground | `#9A6200` | `#FEB43B` |
| coral | `#F97B64` | `#F45F59` |

and the six identity dots — amber `#F5B549`, blue `#538EDE`, green `#44AB62`,
teal `#41969D`, purple `#845FC9`, violet `#AA5BD0` — which are **identical in
both modes**, because they are identity colours rather than surfaces: a workspace
should keep its colour when the user switches appearance.

Two consequences of the sampling are easy to get wrong:

- **Nothing is a neutral grey.** Every surface carries a little red and yellow;
  the light page is cream, not `#F5F5F5`. A "neutral" grey dropped into this
  palette reads as a different, colder app.
- **The amber is a fill, not a foreground.** In the reference it is a button with
  dark text on top, and amber as *text* on a white surface is unreadable. That is
  why `accent` and `accentFill` are separate constants: `accent` is the
  foreground-readable amber (dark in light mode, bright in dark mode) and is what
  every icon tint and `.foregroundStyle` wants, while `accentFill` is the
  reference's button colour and always pairs with `accentOn`. The same split
  applies to `Button`: SwiftUI's `.borderedProminent` paints its label white,
  which fails on amber, so `PrimaryButtonStyle` (`.primary`, `.primaryCompact`)
  draws the fill and sets the label to `accentOn`.

A third consequence, and the one worth knowing before editing this file: **the
values a contrast rule governs live in `JXCodeCore`, not here.** `Palette` owns
the surfaces, the status colours and the dots; `Theme` owns the rendering. That
is not tidiness. The app target has no test target — `JXCodeCoreTests` depends on
`JXCodeCore` only — so a rule stated only in `Theme.swift` is a comment nobody can
enforce. `PaletteTests` asserts every status colour clears 4.5:1 on every light
surface *and* on its own 10 / 14 / 18% wash, and that every dot carries a glyph
at 3:1. Both rules were shown to have teeth by mutation: reinstating the sampled
`warning` fails 6 tests, and making the ink always white fails 7.

---

## The shared collection

Everything above is per workspace. Skills, connectors and automations are not:
they are written once and every agent in every workspace sees them. The agents
themselves sit in the same list, because they are installed once into the
sandbox rather than once per workspace.

It is reachable from the **Shared** block in the sidebar — `Skills`, `Agents`,
`Connectors`, `Automation` — and from `jxcode shared` on the command line. Both
drive the same `SharedStore`, `SkillBinder`, `ConnectorBinder` and
`AutomationRunner`, so a passing CLI run is evidence about the app rather than
about a parallel implementation of it.

Opening one of those four opens it **in a tab**, not in a sheet. A sheet was the
wrong container twice over: it is modal over a window whose entire purpose is to
run several things at once, and it cannot be left open beside a terminal. A tab
is a peer of the terminal tabs, so moving between "what the agents can see" and
"an agent running" is a tab click rather than a dismissal. There is at most one
shared tab — `openShared` reuses an existing one rather than stacking a second —
and closing it leaves the window empty, which is what the dashboard is for.

| | Stored as | Bound into |
|---|---|---|
| **Skill** | `<id>/SKILL.md` + a `skill.json` sidecar | each agent's instruction file |
| **Connector** | `<id>/connector.json` | each agent's MCP config |
| **Automation** | `<id>.json` | nothing — it runs the agent |

### A skill is a file, not a record

`SKILL.md` with YAML frontmatter is the format the agents already use, and it is
the source of truth for the content. The sidecar holds only what the file cannot
express: whether the skill is switched on, and when it changed. A skill stays
something you can open in any editor, and the app never rewrites your prose.

Binding writes a fenced block into each agent's instruction file rather than
copying the skill in. The block names the skill's **absolute path**, and that is
not tidiness: `shared/` is a sibling of `env/`, so it is *not* under the `$HOME`
an agent runs with. A relative path resolves to nothing, and the agent then
reports a missing file rather than a skill it could not find. One copy on disk
also means editing a skill takes effect everywhere at once, with nothing to
re-sync.

Claude Code is the exception that gets both treatments: the block *and* a
symlink into `~/.claude/skills/`, which is where it discovers skills natively. A
directory that already exists under that name and is not one of our links is
left alone and reported — the user may have their own skill there, and replacing
it would delete their work.

### Four agents, four config formats

There is no shared standard for MCP, so binding a connector means writing into
each agent's own file, in its own shape. The differences are not cosmetic:

- **Claude Code** — `mcpServers` with `command` and `args`; a remote server is
  `type: http` plus `url`.
- **Gemini** — the same `command`/`args`, but a remote server must use
  `httpUrl`. A bare `url` means SSE, and getting that wrong is silent: the
  server is listed and never connects.
- **opencode** — `command` is a *single array* holding the executable and its
  arguments, not a string plus an `args` list, and every entry carries `enabled`.
- **Codex** — TOML tables, not JSON.

`ConnectorBinder` holds that per-agent knowledge and nothing else.
`shared/mcp.json` is the record of what JXCode wrote where. Without it, removing
a connector could not be done safely: there would be no way to tell whether an
entry in someone's `mcpServers` was ours or theirs, and guessing wrong deletes
their server.

A connector with an `installCommand` is installed **before** anything is bound.
Binding first would register a server whose binary does not exist, and the agent
would then report a connection failure rather than a missing install — a much
harder thing to diagnose from the agent's side. The install lands in
`shared/bin`, which is on every agent's `PATH`, so the next agent gets it for
free.

### What unbinding leaves behind

Unbind removes exactly what it wrote and nothing else — that is what the
manifest is for. Two consequences are deliberate:

- **A file that only ever held our entries is removed**, not blanked. Leaving a
  one-byte `AGENTS.md` behind would make "never configured" and "configured,
  then unbound" look identical on disk.
- **The first change to a file that already existed copies it once** to
  `<name>.jxcode-backup`. Your text around the managed block is never touched,
  and that copy is never overwritten by a later run, so it stays a record of the
  file as it was before JXCode saw it.
- **The connector ledger is emptied, not removed.** `<root>/shared/mcp.json` is
  JXCode's own record of which servers it registered, and it is what scopes the
  next unbind — so once it exists it survives as `{"managed": []}`. It is the
  one file that behaves this way, and the reason is that an agent whose config
  could not be edited may still be holding a live entry: deleting the ledger
  would strand it there with nothing left to find it by. It is never *created*
  just to say it is empty, so a sandbox that was never bound stays untouched.

### Automations only run agents JXCode can actually drive

An automation is an agent, a prompt and a schedule. Running one means starting
that agent in its documented headless mode — `claude -p`, `codex exec`,
`gemini -p`, `opencode run` — and recording what happened.

Those four are the whole list, on purpose. An unrecognised flag does not fail
loudly: it drops the agent into its interactive TUI, which then blocks forever
waiting for input that a scheduled run will never provide. So an agent with no
documented headless mode is reported as unsupported rather than attempted, and
the picker in the UI offers only the four.

A run is recorded even when it fails. A failure that was not written down would
be retried on every tick forever, and the schedule would look like it was
working while producing nothing.

`AutomationSchedule.isDue` is a pure function of the stored values, so the
schedule logic is tested without a clock or a process — which matters, because
"it ran at the wrong time" is the failure a user would actually notice. One
consequence is worth stating plainly, because the obvious alternative is wrong:
a never-run *daily* automation whose time has already passed today **is** due.
Making it wait a whole day instead deadlocks — nothing else ever sets `last`, so
it would never become due and would never run at all.

---

## Model routing

Register any number of backends, pick one model, and every agent in the app
talks to it — without any of them knowing. A loopback HTTP server
(`ModelRouter`) presents the selected backend in whichever API shape the calling
agent expects.

```
Claude Code ──Anthropic Messages──┐
Codex / Gemini / opencode ──OpenAI┼──► 127.0.0.1:4141 ──► your backend
                                  │      (translate)
```

Switching backend is a change to `RouterState`; the listener never restarts, and
the next request picks it up.

### Endpoints

| Route | Purpose |
|---|---|
| `GET /health` | Current provider, model and upstream URL |
| `GET /v1/models` | Model list, in whichever shape the caller expects |
| `POST /v1/messages` | Anthropic Messages (Claude Code) |
| `POST /v1/messages/count_tokens` | Estimated, locally |
| `POST /v1/chat/completions` | OpenAI Chat Completions |

### The four things the translation has to get right

`Translation.swift` exists because the two APIs disagree in ways that produce
silent misbehaviour rather than errors:

1. **Tool results live in different places.** Anthropic puts `tool_result`
   blocks *inside* a `user` message, alongside any new text. OpenAI requires a
   separate message with role `tool` and a matching `tool_call_id`, and it must
   immediately follow the assistant turn that requested it. Getting the order
   wrong makes the upstream reject the whole conversation.
2. **Tool arguments are an object on one side and a JSON *string* on the other.**
   `input` is a real object; `arguments` is a string that has to be re-parsed on
   the way back.
3. **`system` is a message on one side and a top-level field on the other**, and
   on Anthropic's side it may be an array of blocks carrying `cache_control`.
4. **Stop reasons and streaming event names differ entirely.** OpenAI's stream is
   a flat run of deltas with no block boundaries; Anthropic's is a state machine
   of `content_block_start` / `content_block_delta` / `content_block_stop`
   triples keyed by index. The router synthesises the boundaries.

Two details worth knowing:

- **Reasoning models work.** vLLM, DeepSeek and OpenRouter return
  `reasoning_content` (or `reasoning`); that maps onto Anthropic `thinking`
  blocks, so a reasoning model's chain of thought is surfaced rather than
  silently discarded.
- **`finish_reason` is not trusted over the content.** Several backends report
  `stop` even when the turn ended in a tool call, and Claude Code only continues
  the agent loop on `tool_use`. If any tool block was emitted, the stop reason
  says so.

### Model names are rewritten

Claude Code hard-codes its model names and will not accept a rewrite on its own
side — it sends `claude-sonnet-4-5-20250929` and expects that back. The router
substitutes the selected model on the way upstream and echoes the requested name
on the way back, because the client keys its context-window table off that name.
A model the backend actually advertises is honoured, so a multi-model server
stays addressable.

### `count_tokens` is estimated, deliberately

Claude Code calls it to decide when to compact its context. Most
OpenAI-compatible servers have no counting endpoint, so proxying would fail for
exactly the backends this feature exists to support. `TokenEstimator` counts CJK
characters as one token each and Latin text at ~3.6 characters per token, and is
biased slightly low so the client compacts a little early rather than
overflowing. Returning zero — or an error — would be worse, because the client
would believe it has unlimited context.

### Binding agents to the router

Two mechanisms:

- **Environment variables**, injected by `SandboxEnvironment` into every process
  the app launches. This covers any agent that honours `ANTHROPIC_BASE_URL` or
  `OPENAI_BASE_URL`.
- **Config files**, for the agents that need more. `AgentConfigWriter` writes
  Claude Code's `settings.json` and Codex's `config.toml`, merging rather than
  replacing and backing the original up once as `*.jxcode-backup`.

Four rules it follows:

- **Only the sandbox copy is touched.** Your host `~/.claude` is never written
  to — there is a test that walks every file written and asserts it is inside
  the sandbox root.
- **Merging, not clobbering.** `settings.json` also holds permission rules and
  hooks; those survive.
- **No guessing.** Agents whose config format is not documented and stable get
  environment variables only, and the report says so. Writing a broken config is
  harder to diagnose than doing nothing.
- **Unbinding removes the file it created.** A `settings.json` holding only our
  `env` keys, or a `config.toml` holding only our managed block, is deleted
  rather than left behind as `{}` or zero bytes — a file in your home that was
  never there is worse than no file. The `*.jxcode-backup` is what distinguishes
  the two cases: it exists only if the file predated JXCode, so its absence is
  the record that there is nothing to restore but "no file".

Codex needs care: TOML forbids duplicate keys rather than letting the last one
win, so a user's own top-level `model = …` would make the whole file invalid.
The writer comments such lines out rather than deleting them, and only for keys
before the first `[table]` header — a `model =` inside a section belongs to that
section and is left alone. Unbinding puts them back, so a bind→unbind cycle
leaves the user's own setting live rather than silently disabled.

---

## Local models

Pillar 02 lets you point the agents at a backend someone else runs. Pillar 03
runs the model here. The interesting part is not starting `llama-server` — that
is one `Process` — it is **deciding what to pass it**, because llama.cpp's
defaults are tuned for a machine with a discrete GPU and a 4k context, and this
is an Apple Silicon laptop with unified memory and models claiming 128k windows.

```
GGUF file ──► GGUFReader ──► GGUFModelInfo ──┐
                                             ├──► ModelOptimizer ──► argv
HardwareProfile (sysctl) ────────────────────┘
                    ▲
sibling files ──► ProjectorNameMatcher
```

### Reading the header

`GGUFReader` parses the container: magic `GGUF`, version, tensor and metadata
counts, then key/value pairs. Two properties matter more than they look.

**Keys are architecture-scoped.** A model does not have
`context_length`; it has `qwen35.context_length`. The architecture name comes
from `general.architecture` and prefixes every geometry key. Reading the
architecture first and prefixing every subsequent lookup is mandatory — a
bare-key lookup returns nothing, and the failure is silent: the model loads with
llama.cpp's 4096 default instead of its trained 128k, and nothing anywhere says
so. There is a test for the negative case
(`testKeysScopedToTheWrongArchitectureAreNotFound`) as well as the positive one.

**The header is traversed, not materialised.** These models carry ~11 MB of
metadata, of which `tokenizer.ggml.tokens` alone is ~150,000 strings. Allocating
that to read one integer costs hundreds of megabytes and about 0.2s per model.
So values are walked structurally and only converted when asked for, with a
size ceiling (`maxMaterializedArrayElements`, default 512) above which an array
is skipped rather than loaded.

That skip is the subtle part. A skipped array is **not** reported as
`array([])`, because that claims zero elements when there are 150,000 — a lie
that later code would believe. It is reported as absent, and the key is recorded
in `GGUFHeader.skippedKeys` so the UI can still say the key was there. A test
caught this: the first implementation stored `.array([])` and the assertion
`nil` vs `Optional(0)` was the design flaw surfacing.

Hostile input is bounded throughout — `kv_count`, string lengths and total
header bytes are all capped, because a corrupt file can otherwise ask for a
40 GB allocation before anyone notices.

### Pairing a vision projector

A multimodal GGUF needs a second file, the `mmproj`. Real model directories use
**four** incompatible naming conventions, and this machine's library contains
all four:

```
Ornith-1.5 9B Q8_0 mmproj.gguf          suffix, space-separated
mmproj Ornith-1.5 9B Q8_0.gguf          prefix, space-separated
mmproj-Ornith-1.5-9B-Q8_0.gguf          prefix, dash-separated
models--org--name/snapshots/<sha>/…     HuggingFace layout
```

Separators differ between the two halves of the same pair (`Q8_0` vs `Q8-0`),
so normalising separators and comparing token sets is the only approach that
survives contact with real files.

Two decisions are load-bearing:

- **Projector markers are stripped from the projector side only.** `mmproj` is a
  label on one side of the pair and part of the identity on the other.
  `Llama-3.2-11B-Vision.gguf` and `Llama-3.2-11B.gguf` are *different models*,
  so `vision` must not be treated as noise in a model's name.
- **Metadata is a veto, not a bonus.** The first implementation *boosted* a
  pairing when the projector's `projection_dim` equalled the model's
  `embedding_length`. That was wrong: 4096 is ubiquitous, so the equality is
  satisfied by coincidence and the projector attached to an unrelated model.
  llama.cpp refuses mismatched pairs, so an *inequality* is a hard rule-out
  while an equality proves nothing. Inverting it into a veto fixed a real
  mis-pairing that the test suite was already reporting.

Filename heuristics are only a fallback. `general.architecture == "clip"` is the
authoritative signal that a file is a projector, and files without a `.gguf`
extension are identified by magic bytes — which is how a real 638 MB model in
this library was found at all, sitting there with no extension.

### Deciding how to run it

`ModelOptimizer` turns metadata plus hardware into arguments, and every argument
carries the reason it was chosen so the UI can show its reasoning rather than
asking for trust.

The constraint that dominates everything is the **KV cache**, which is
`layers × kv_heads × (key_dim + value_dim) × bytes_per_element`. For the 9B model
here that is **128 KiB per token**, so its trained 262,144-token context would
need 34 GB of cache before a single weight is loaded. Context length is
therefore not a preference; it is arithmetic against memory.

That arithmetic is why the tool exposes **two** policies rather than one:

| Policy | Meaning |
|---|---|
| `MemoryPolicy` | how much of physical RAM the plan may claim: safe 55%, balanced 70%, maximal 80% |
| `CachePolicy` | how far the KV cache may be quantised to buy context: quality (f16 only), balanced (f16 or q8_0), context (adds q4_0) |

They are genuinely different questions — how much can I spend, versus how much
fidelity will I trade — and collapsing them into one slider would hide the
choice that matters most. On the 9B model on this machine, `balanced` yields
65536 context at q8_0 while `quality` yields only 32768 at f16. Same machine,
same model, half the context, because of one setting.

Quantised cache byte counts include block overhead: q8_0 is 34/32 = 1.0625
bytes per element, not 1. Rounding that down is a silent 6% overcommit.

Two arguments are not tuning but correctness:

- **`--parallel 1` is mandatory.** `-c` is the *total* context divided between
  slots, and llama.cpp's default is `auto` (−1). An agent asking for a 128k
  window would silently receive four 32k ones.
- **`-t` counts performance cores only.** llama.cpp defaults to all cores, but
  the generation loop is latency-bound and serial, so the slow efficiency cores
  become the critical path rather than adding throughput.

And one argument is a version problem rather than a tuning one:
`--flash-attn` was a bare flag for years and then grew an optional value
(`--flash-attn on|off|auto`). Passing the wrong form is a startup argument error
that looks like a bug in this app. `LlamaServerCapabilities` parses the real
`--help` text once and renders the arguments to match, rather than guessing.

### Running it

`LlamaServer` supervises the process: bounded log tail, `/health` polling with a
fail-fast if the child exits, and `SIGTERM` → `SIGKILL` escalation on stop.
`LlamaRuntimeLocator` searches the **sandbox prefix first**, then the host, then
copies bundled inside other apps (LM Studio nests its backends several levels
deep, hence a bounded walk). Which one was found is reported rather than
hidden: a binary in `/opt/homebrew` is the user's own and not ours to update.

A running model is registered as an ordinary provider, so pillar 02's router can
route every agent at it — the two pillars meet exactly there.

### What real files taught it

Driving the implementation from an actual model library, rather than fixtures,
found things fixtures would not have:

- **Filenames lie.** `DeepSeek-R1-0528.gguf` is a Qwen3 8B fine-tune
  ("Josiefied DeepSeek R1 0528 Qwen3 8B"). Metadata is authoritative.
- **Extensionless models exist.** One real 638 MB GGUF has no `.gguf`
  extension and is findable only by magic bytes.
- **Dangling symlinks are normal**, not exceptional — 10 in one HF cache here.
- **Orphan projectors are normal too**, and reporting them is more useful than
  attaching them to something arbitrary.

The GGUF reader was independently cross-checked against a from-spec Python
parser written for the purpose; the two agreed on every field for two models.
The KV-cache arithmetic was verified by hand against the planner's output
(22 layers × 4 KV heads × 64 head_dim × 2 × 2 bytes × 2048 = 44 MiB).

---

## Importing your existing config

A fresh sandbox starts empty, which means retyping settings. `jxcode import`
copies a curated subset once, after which the two diverge permanently:

```bash
./.build/debug/jxcode import --dry-run   # show the plan
./.build/debug/jxcode import             # apply
```

Two deliberate choices:

- **Symlinks are recreated, not followed.** `~/.claude/skills` is often a
  symlink (into iCloud, or a shared repo). A plain `cp -r` dereferences it and
  duplicates gigabytes. Links that escape the config directory are flagged in
  the plan rather than silently copied.
- **Session state is skipped** — `projects/`, `todos/`, `shell-snapshots/`,
  history files. Large, machine-specific, useless in a fresh sandbox.

Git is handled differently: the sandbox `.gitconfig` `include`s your host one
read-only, so commits have your identity without credentials being copied in.

---

## Caveat: `getpwuid()` ignores `$HOME`

`getpwuid(getuid())->pw_dir` returns the **real** home directory no matter what
`HOME` is set to. This is a property of the C library, not something the
environment can override.

A tool that resolves home through `getpwuid` rather than `$HOME` will reach the
host directory. `jxcode doctor` reports this explicitly. It is the reason
`CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `GEMINI_CONFIG_DIR` are set explicitly:
those remove the fallback for the agents that matter, instead of relying on
`$HOME` being consulted.

Closing this fully would require a VM or container, which was deliberately not
the chosen trade-off — see Roadmap.

---

## Verification

`swift test --disable-sandbox` — **816 tests, 0 failures, 1 skipped.**

Six layers, and the distinction is the point:

- **Static** — the environment dictionary is correct, `PATH` has no host
  entries, generated init re-asserts in the right files.
- **Dynamic** (`IsolationProofTests`) — spawns real processes through
  `Sandbox.run` and checks where they actually land. A dictionary can be right
  while the process that receives it escapes, because the shell is free to
  rewrite its own environment. That is not hypothetical: the dynamic test is
  what caught the `path_helper` leak.
- **End-to-end** (`RouterEndToEndTests`) — starts a real OpenAI-compatible
  server on a loopback socket, starts the router, and drives it with real HTTP,
  asserting on the raw SSE transcript. A stub would not have caught either of
  the bugs below.
- **Against real files and a real binary** (`RealModelCorpusTests`,
  `RealLlamaServerTests`, `RealModelReportTests`) — scans the actual model
  library on this machine, and drives the actual `llama-server` (build 10150):
  parses its real `--help`, confirms the adapted arguments are accepted, serves
  a model, and asserts `/health`, `/v1/models` and `/v1/chat/completions` all
  return 200. Fixtures encode what the author *believed* the format was; this
  layer is what corrects that belief.

A fifth layer has since earned its place: **repetition**. Three of the bugs
found here — the pty exit status, the unreaped child, and the lost first output
— are races, and a race that fires one time in five passes a single-shot test.
`PTYExitStatusTests` and the launch-path tests run each case 8–12 times. That is
also how they were confirmed as real before anything was changed: the zombie was
observed on 10 of 12 runs against the old code, which is a measurement rather
than an argument.

And a sixth: **mutation testing**, which is less a layer than a question asked of
the other five — does any of this fail when the rule is broken? It is the only
way to find a guard that is green because it tests the wrong thing, and it found
two of those plus one crash-instead-of-failure. Details above.

A seventh came from asking the same question of *coverage*. `xcrun llvm-cov` over
a coverage build reported `ModelCatalog.swift` at **6.1% of lines** — 154 of 164
never executed — while being half of requirement 2. It was unreachable from the
suite because it needs an HTTP server, which is a reason to build one, not a
reason to leave it. Writing the tests took it to **96.97%** and immediately
exposed an error case that could not fire at all (below).

The same sweep, run over every file, turned up four more gaps that reading had
not: `SandboxEnvironment.report()` — an entire user-facing function, unexecuted,
in the isolation feature; `ProviderStore.remove(id:)`, so deleting a registered
provider was untested; every `ModelCatalogError` message, which is the whole
diagnostic experience when a backend does not work; and the `image` /
`tool_result` halves of the Anthropic codec, which is how tool output travels
back to Claude. Core-layer line coverage went from 88.08% to **90.17%**, and the
four files moved to 99.48%, 99.32%, 96.97% and 91.32%.

The last of those gaps is a pattern worth naming: **`PTYSession.write`, `.resize`
and `.terminate` had no tests because every caller was in the app target.** Those
are the three things a user does to a terminal all day — type into it, resize the
window, close the tab — and they sat at 0% while the file around them was
heavily tested. One grep for callers found them; `PTYInteractiveTests` now
drives all three against real processes (`stty size` for the window, `read line`
for stdin, and a child that ignores SIGHUP for the SIGKILL escalation).
`PTYSession` went from 59.36% to **86.93%**, with every function now executed.
What remains uncovered there is the child-side `execve` path, a `forkpty`
failure, and `reap()` — none of which can be forced from outside.

Coverage is a *search* technique here, not a target. The one file it flags that
is not a gap is `GGUFModelInfo.swift`: 38.60% of regions missed with 0 lines
missed and 100% of functions executed, because the struct is a `Codable` with 17
optional properties and the compiler synthesises a region per property per
branch. Every hand-written line runs. Chasing that number would mean testing
`JSONDecoder`.

Covered dynamically: `$HOME`, `~` expansion, writing to `$HOME`, npm prefix,
`BUN_INSTALL`, `ZDOTDIR`, `CLAUDE_CONFIG_DIR`, and that the global `CLAUDE.md`
resolves to the sandbox copy rather than the host's.

The router seam is proved the same way (`RouterEnvironmentProofTests`), because
a correct dictionary is not the same as a correct process. Agents find the
router through `ANTHROPIC_BASE_URL`, so if the generated shell init dropped it
every agent would talk to the real API instead — silently, with no error. The
tests spawn a real login shell and a real nested child and assert the URL
arrives, and that it arrives *absent* rather than empty when no router is
configured.

The one worth calling out is `ANTHROPIC_API_KEY`. Claude Code sends it as
`X-Api-Key`, so an **empty** value is what stops a real key exported in the
user's shell from being inherited and sent straight to `api.anthropic.com`. An
empty environment variable is exactly the kind of thing an `execve` boundary can
quietly drop — which would restore the bug while every unit test still passed.
`${VAR+SET}` distinguishes "set but empty" from "unset", and the test checks
that distinction in both the shell and a child process.

The [Tools](#tools) grid added a layer of the same kind, one step up from a unit
test: `ToolCatalogTests` builds real throwaway sandbox roots and real host homes,
puts executable stubs in them, and makes real symlinks — because the properties
worth pinning there are filesystem properties rather than logic ones. `link` must
refuse to clobber a file it did not make; `unlink` must leave a real install
alone; linking twice must be idempotent; and a link must follow its target when
the tool moves. Each of those is a statement about what a call *does to a
directory*, and a mock would have let all four pass while the real code deleted a
user's file.

### The CRLF trap, and why the parser works on bytes

Two bugs found by the end-to-end tests, both the same root cause, both silent:

**In Swift, `"\r\n"` is a single `Character`.** CR+LF forms one extended
grapheme cluster, so `string.firstIndex(of: "\n")` finds *nothing* in a
CRLF-terminated stream — there is no standalone LF character to find.

- The SSE parser's loop therefore never executed and every event was dropped.
  No error, no exception: the stream just produced nothing, which to a user
  looks like the model hanging before its first token.
- The HTTP head parser had the same flaw, so a CRLF request head was never split
  into lines. The request line still parsed *by luck* (method and path are
  followed by a space), but every header was lost — including `Content-Length`.
  The body was then silently discarded, and the router reported "empty body".

Both now work on UTF-8 bytes and search for the byte `0x0A`, which also means a
chunk boundary splitting a multi-byte scalar cannot corrupt it: only complete
lines are ever decoded. URLSession, every real HTTP client, and several SSE
servers use CRLF, so this was the common path rather than an edge case.

The test fixture emits CRLF on purpose, so neither bug can come back.

### The doubled `/v1`, and why only a real backend found it

A local llama-server was registered with `chatPath = "{base}/v1/chat/completions"`
while `normalizedBaseURL` *also* appends `/v1` to a bare `host:port`. Every chat
request therefore went to `/v1/v1/chat/completions` and llama-server answered
`404 File Not Found`. Routing an agent at a local model — the combination of
pillars 02 and 03, and the thing this app exists to do — did not work at all.

It survived a green suite for a specific and instructive reason. The three
endpoints that were exercised never reach `chatPath`:

| Endpoint | Why it hid the bug |
|---|---|
| `/v1/models` | **Synthesised by the router** from its own configuration, so no upstream call is made and no path is used. |
| `/props` | Strips the `/v1` before asking, precisely because `/v1/props` 404s — so it was accidentally immune. |
| Router E2E tests | Use a fake upstream registered as `.openAICompatible`, whose paths were already correct. |

Only a real completion, through a real router, to a real local backend reaches
that path — and nothing did. `RealRouterChainTests` now does, and it fails on
the old code.

The fix is that a local llama-server *is* an OpenAI-compatible server, so it
shares those paths instead of restating them with the prefix baked in. The
regression guard asserts the **resolved URL**, not the path template: both
halves looked correct in isolation, and only resolving them together shows the
doubling. It checks every provider kind, because a local backend is not special
and the same mistake could be made for any of them.

### The exit code that was always zero, and the zombie behind it

`PTYSession` watches its child two ways: a read source on the pty master and a
process source on the pid. On a short-lived command **both become ready at the
same instant**, and the original code let the read source win — it finished the
session with a hardcoded `exitCode: 0` on EOF/EIO.

Two things followed, neither visible from a passing suite:

- A command that exited 7 was reported as 0. `jxcode pty` turns that into its
  own exit status, and a tab shows `exited (0)` for a run that failed.
- `finish()` cancels the process source, and `waitpid` lived *only* there. So
  whenever the read source won, the child was never reaped: **a zombie per tab**,
  for the life of the app. Measured over a loop of 12 runs, 10 left the child
  unreaped.

The exit status can only come from `waitpid`, and `waitpid` needs the child to
be gone — which is exactly what the process source signals. So the process
source is now the only thing that may end a session; the read source reads and
stops. `finish()` closes the master fd itself rather than leaving it to the read
source's cancel handler, because a source that cancelled *itself* on EOF was
taking the descriptor with it and any later read hit a closed number.

`PTYExitStatusTests` pins all four behaviours — exit status, signal death
(`128 + signal`), reaping, and a non-truncated tail — and runs each a dozen
times, because a race that fires one time in five will pass a single-shot test.

### One launch path, or the GUI and the CLI drift

`Sandbox`'s doc comment claimed "exactly one place where the environment is
decided". It was not true. Three copies of "build a `PTYSession` and start it"
existed — the library's `launch`, the SwiftUI terminal controller, and the CLI's
`pty` command — and they had already diverged:

- the GUI's copy **dropped the agent's own environment overrides**, so an agent
  tab and a CLI tab ran different environments;
- the CLI's copy installed `onData`/`onExit` *after* `start()` returned, and
  `PTYSession` does not buffer — it drops bytes when no handler is attached — so
  the first output of a run could be lost. For an interactive shell that is its
  opening prompt.

Both were invisible: every built-in agent ships an empty environment, and the
lost-output window is a race. It is the same shape as the doubled `/v1` — two
paths that agree only by coincidence — so the fix is the same in kind: one entry
point, with a `configure` hook for the part the callers genuinely differ on
(wiring callbacks before the fork).

The same review turned up two pieces of dead code of exactly the kind the
earlier audit criticised: `Sandbox.launchShell` (a second launch path nothing
called) and `AgentRegistry.isEscaping` (nothing called it *because the doctor
had inlined its own copy of the same containment rule* — so the tested version
and the version users saw could drift). Both are gone; the doctor now calls the
registry.

### The self-audit that had no tests

Removing `isEscaping`'s dead copy raised a worse question: if the doctor had
inlined that rule, what else did it do untested? The answer was everything.
**No test mentioned `Doctor` at all.**

That is the worst place to have none, because the doctor's failure mode is
silence. Every check is a claim that the sandbox holds, and if one stops firing
the report still ends with `Sandbox holds.` — it looks *healthier* the more it
is broken. `DoctorTests` now covers it, weighted towards that property:

- every expected check id must be present, so deleting one fails loudly rather
  than quietly improving the verdict;
- a real leak — `CLAUDE_CONFIG_DIR` pointed at the host, an empty variable, an
  agent binary resolving outside the root — must be reported as a failure;
- a warning and an informational note must **not** make the report unhealthy,
  because `/usr/local/bin` and the un-fixable `getpwuid()` hazard would
  otherwise teach users to ignore it.

**A leak report that cried wolf.** The per-agent check flags a binary resolving
outside the sandbox, on the grounds that it would write to the host home. That is
true of a Homebrew toolchain. It is not true of `/bin/zsh`, which is what
`Plain shell` runs: the OS shell is outside the sandbox by definition and is
shared deliberately, because a sandbox with no `sh`, `sed` or `git` cannot run
an agent at all. Counting it as a failure made the sidebar read "1 leak" on a
sandbox that was in fact holding — and a leak report that is wrong once is a
leak report nobody reads. `SandboxEnvironment.baseSystemDirectories` now names
those directories once, and both `buildPath()` and the escape check consult it,
so "what we put on `PATH`" and "what we are willing to call reachable" cannot
drift apart.

The tests missed it because every case ran `Doctor.run` *without* a registry, and
the per-agent checks only run when one is supplied. The app always supplies one.
`testAHealthySandboxWithTheRealRegistryHasNoFailures` now covers that path.

### Mutation-testing the guards

A test only guards something if it fails when the behaviour it describes is
broken. So each bug fixed above was reintroduced, one at a time, to see whether
anything went red. **Seven of eight were caught. The exceptions were the
interesting part.**

**A fix with no guard at all.** The llama vocabulary discriminator had been
changed from exact equality (`128256` / `32000`) to bands, because a real
fine-tune on this machine reports `130560` and was silently loading with no
template. Reverting the bands left the *entire suite green* — every value the
tests used was one of the two constants the old rule hardcoded. The tests
encoded the assumption the fix existed to remove. `testTheLlamaDiscriminatorUsesBandsNotExactSizes`
now pins `130560`, both band edges, and the values one step outside them.

**A test that proved nothing about its own fix.** The truncation test's comment
described the exact race its fix protects against; deleting that fix changed
nothing. The window cannot be forced from outside — a child writing more than
the pty buffer holds blocks until the reader drains, so it cannot exit with
output pending — so the test now says plainly what it does *not* cover, and
`testNoOutputArrivesAfterExit` pins the part that is observable: `onExit` is a
barrier.

**A crash wearing a build error's clothes.** One mutation *was* caught, but the
failing `XCTAssertEqual(count, 1)` was followed by `problems[0]`, a fatal error
on an empty array. The process died, taking every other result in the binary
with it, and the run reported a compile error. Five such subscripts are gone.

**A mutation that never mutated anything.** The first attempt to check the pty
write path reported MISSED — the tests stayed green while `write()` was
supposedly a no-op. The mutation was `return` placed before a `writeQueue.async
{ … }` closure, which Swift parses as `return writeQueue.async { … }`, so the
write ran anyway. The compiler warned (*"expression following 'return' is
treated as an argument of the 'return'"*) and the harness, which only looked for
`' failed`, scored a no-op mutation as an unguarded rule. Re-run with a shape
that cannot be misparsed, the same tests caught it seven times over. **A MISSED
verdict is a claim about the mutation, not about the tests** — prove the mutant
is dead before concluding anything is unguarded.

### The comment that was wrong about which source ends the session

The pty fix above was explained, in a comment, as *"the exit status can only come
from `waitpid`, so the process source is the authority on ending a session."*
That reads well and is false.

Line-level coverage over 66 sessions: the process source's handler fired **once**,
and the read source ended every session. A pty master reports EOF when the
session leader exits, which is also the first moment `waitpid` has a status, so
the two become ready together and the read source is simply dequeued first —
`finish` cancels the process source before it ever runs. The fix was correct; the
explanation was not.

What the coverage also showed is that `reap()` had **never executed** — not once.
It is reachable only if the process source fires while `drain` still has buffered
output, in which case `drain` returns on a short read and something has to end
the session. That ordering is not forceable from outside, so the honest answer is
to say so in the code rather than to write a test that pretends otherwise.

The branch that *is* forceable is the one that makes `reap` necessary at all:
`reachedEOF` must step aside when the pty closes while the child is still alive,
because there is no status to take yet. Nothing had ever produced that either.
It can be produced — a child that closes its own pty descriptors and keeps
running makes the master report EOF about a second before it exits — and
`testAPtyThatClosesBeforeTheChildExitsStillEndsWithTheRealStatus` does exactly
that. Reintroducing the old "finish at EOF" behaviour makes it fail with
`reported as 0` instead of `9`, which is the bug it exists to catch.

Getting there took a wrong turn worth recording: `sh -c 'exec 0<&- 1>&- 2>&-'`
does *not* hang up the pty. `lsof` shows bash holding fds 0, 1 and 2 on the tty
afterwards, and the master only sees EOF when the child exits — so a shell-based
test would have looked correct while never exercising the branch at all.

### An error case that could not fire

Writing the `ModelCatalog` tests surfaced something the code had been hiding:
`ModelCatalogError.emptyCatalog` was **unreachable**. Every branch of
`decodeModels` either returned a non-empty list or threw on the way out, so the
`guard !models.isEmpty` in `probe` could never fire.

The consequence was not academic. A local server running perfectly with nothing
loaded — the most ordinary state a backend is ever in — produced a `decoding`
failure whose entire message was the raw JSON body, instead of "no models
loaded". Recognising an envelope is not the same as requiring it to be non-empty,
and the two had been conflated. `decodeModels` now returns a recognised-but-empty
envelope, which is what makes the error reachable and its message useful.

### The segmented control that chose its own tab

The Shared pane was built with a stock segmented `Picker` bound to the selected
section. It looked right and compiled, so the only way this was ever going to
surface was by opening the window — which is exactly what happened, and what the
screenshot showed was the *wrong tab*.

Instrumenting `body` settled it in one run:

```
JXTRACE SharedPane body, section=skills
JXTRACE SharedPane body, section=connectors
JXTRACE SharedPane body, section=automations
```

Three sections rendered in a single launch, in ascending order, with the binding
being written to as the control laid itself out. The tab the user saw was
whichever segment settled last, which had nothing to do with the one they asked
for. Nothing in the code set `sharedSection` more than once.

It is now a hand-rolled strip of buttons over `Theme`, which is both
deterministic and consistent with the rest of the app's chrome — the one
argument for keeping the stock control was that it was already written, and it
had just demonstrated that "already written" is not the same as "correct".

The same run is why the trace exists in the write-up at all: the pane is a
visual deliverable, and a UI that only compiles is not a UI that has been
verified. Note that macOS Accessibility permission was unavailable in this
environment, so a real click could not be driven; the four sections were each
opened at launch instead, and the section binding was confirmed from the trace
rather than from a click.

### The comment that promised a deadlock

`AutomationSchedule.isDue` carried a comment stating that a never-run daily
automation "should wait until tomorrow, not fire the instant it is created".
The code did the opposite, and the code was right.

Implementing the comment would deadlock: for a daily automation with no `last`,
nothing else in the system ever sets `last`, so an automation that refuses to
become due until tomorrow would never become due at all. Running once at the
first opportunity and settling onto the schedule afterwards is the only
behaviour that terminates. The comment now says so, and
`testADailyAutomationThatHasNeverRunIsDueOnceTodaysTimeHasPassed` pins the
behaviour it used to misdescribe — because the next person to read that comment
would have "fixed" the code to match it.

### The unbind that invented three config files

`jxcode shared-revert` on a sandbox where nothing had ever been bound reported
this:

```
cleared the shared connectors from …/env/home/.claude.json
cleared the shared connectors from …/env/home/.gemini/settings.json
cleared the shared connectors from …/env/home/.config/opencode/opencode.json
```

Every one of those files had just been created, by that command, containing
`{}`. Unbinding something that was never bound was materialising three config
files in an agent's home directory and then reporting that it had cleared them.

The same writer had two further problems, both in the backup:

- **`backUp` ran on the way out as well as the way in.** On a removal the file
  already held our own block, so the backup recorded *our* content — and because
  `backUp` skips when a backup already exists, that wrong copy became the
  permanent one. The safety net had turned into a decoy.
- **A file we created was left behind, blank.** `AGENTS.md`, `GEMINI.md` and
  `config.toml` survived revert as one-byte files, which makes "never
  configured" and "configured, then unbound" look identical on disk.

The fix is one rule in three places: **a writer must not create a file in order
to remove something from it, and must not leave behind a file that only ever
held its own content.** The presence of a backup turns out to be exactly the
record needed — `backUp` runs on the first write to a file that was already
there, so a missing backup means we created it, and the state to restore is
"no file".

How the last of those was found is the part worth keeping. The first fix covered
`writeJSON` and `writeTOML`; the JSON files were then correctly removed while
the three markdown files were not — because `SkillBinder.revert` does not go
through `bind`, and makes the same decision on its own path. A fix applied to
"the code that writes this" is not a fix until every path that writes it has
been found. The regression tests now assert the *observable* rule — "no agent
still lists the shared skills" — rather than "the file is gone", so they hold on
both paths and would have caught the omission.

### The ledger that recorded its own emptiness

That rule had a fourth home, one directory over. `ConnectorBinder.revert` ended
with an unconditional `writeManifest(.empty, …)`, so reverting a sandbox that had
never bound anything created `<root>/shared/mcp.json`:

```json
{ "managed": [], "mcpServers": {} }
```

The test that caught it was not a new one. It was the *existing*
`testRevertingOnACleanSandboxCreatesNothing`, which until then only checked the
eight known config and instruction files — and so passed, while the claim in its
own name was false. Snapshotting the whole tree and comparing it before and after
is what turned the name into an assertion.

This one is milder than the other three: `shared/` is JXCode's own directory, not
an agent's home, so nothing about what an agent sees changes. But it is the same
rule, and `apply` was symmetric — `shared-bind` with an empty collection also
wrote a ledger, in order to record that it had nothing to record. Both now write
only when there is something to say, or when a ledger already exists to correct.

That second clause is deliberate, and is the one place this file is *not* deleted
when it becomes empty. The manifest is what scopes the next revert; a `.refused`
agent means an entry may still be live in a config JXCode could not edit, and
dropping the manifest would strand it there with nothing left to find it by. So
it is emptied, never removed — the opposite of the rule above, for a reason that
does not apply to an agent's config file.

### The other writer, with the same two defects

The rule had been applied to `SkillBinder` and `ConnectorBinder` — the two
*writers of the shared collection*. `AgentConfigWriter` writes a different thing,
the per-workspace router config, and it had never been given the same treatment.
A scan for the pattern rather than a hunch is what found it: every other file in
`Sources/` that writes to disk writes JXCode's **own** state into JXCode's **own**
directory, where no backup is owed and the rule does not apply. `AgentConfigWriter`
is the one that writes into an agent's home.

It had both defects, in `revert`:

- `.claudeSettings` wrote `updated` unconditionally, so a `settings.json` holding
  nothing but our `env` keys came back as `{}`.
- `.codexConfig` wrote `stripped` unconditionally, so a `config.toml` holding
  nothing but our managed block came back as a zero-byte file.

Neither had a `hasBackup` check. Both now remove the file instead, and report
that they did.

The lesson repeated itself almost exactly. The existing test
`testRevertDropsTheEnvObjectWhenItBecomesEmpty` asserted only that `env` was nil
afterwards — which is true of a `{}` file — so it passed while the file it was
nominally about sat in the user's home. It now gives the file a key of the user's
own, so the test is about *the `env` object* rather than accidentally about *the
file*, and two new tests cover the file's own lifecycle. That is three times now
that a passing test turned out to be asserting the wrong thing, and each time the
tell was the same: **the name promised more than the assertions checked.**

Verified end to end with `jxcode bind --model qwen3-coder` then `jxcode unbind`:
on a clean sandbox both files are removed; with a pre-existing `settings.json`
(`numStartups`, `MY_OWN_VAR`) and `config.toml` (`approval_policy`), both survive
bind *and* unbind with the user's keys intact and zero `jxcode` markers left.

The trailing newline was the one thing left in this section as "recorded rather
than fixed", and it did not stay recorded for long — because the reason given for
deferring it was the wrong reason. It is not whitespace *fidelity* as opposed to
file lifecycle. It is the same rule: revert is supposed to put the file back, and
a file that no longer ends in a newline has not been put back.

The cause turned out to be a function serving two callers who want opposite
things. `removeManagedBlock` and `ManagedBlock.removing` are the **writers'**
helpers: they trim and collapse blank lines, which is right when composing a
fresh file — the block is written back with a blank line beside it, so a rewrite
restores whatever the collapse took. That justification does not survive the
*last* removal. On revert there is no rewrite, so the user's trailing newline and
any run of blank lines they wrote are simply gone.

Each now has a shape-preserving sibling used by `revert` and **only** by `revert`,
which removes the block's lines plus the single blank line the writer put beside
it — on whichever side the block sits, since markdown is prepended and TOML is
appended — and touches nothing else. It returns the file's trailing newline as
part of the text, so callers must not append one of their own.

Both paths now give the file back byte for byte:

```
before: b'key1 = "a"\n\n\n[table]\nkey2 = "b"\n'
after : b'key1 = "a"\n\n\n[table]\nkey2 = "b"\n'   IDENTICAL
```

The same pattern was behind all of this, and it is worth naming: **a helper
written for the write path, reused on the revert path.** It showed up as the
`backUp`-on-the-way-out bug, as `SkillBinder.revert` not going through `bind`, and
now as two removal helpers that reformat. Revert is not the inverse of bind
unless someone makes it so.

### The fix that only covered half the path

Making `revert` shape-preserving was not enough, and the test that was supposed
to prove it was written the wrong way round: it bound **once**, then reverted.
That passes even with the bug, because the first write is clean — the block is
appended to the user's text and nothing of theirs is touched. It is the *second*
write that re-derives the body from a file that already contains our block, and
that is where the collapse happened:

```
after bind #1: key1 = "a"\n\n\n[table]\nkey2 = "b"\n\n# >>> jxcode connectors >>>…
after bind #2: key1 = "a"\n\n[table]\nkey2 = "b"\n\n# >>> jxcode connectors >>>…
               ^^ a blank line of the user's, gone — and revert cannot put it back
```

The writer's `removing` collapsed **every** run of blank lines in the file, not
just the gap our block left. So a user who re-bound — the ordinary case — lost a
line of their own text. Both helpers had the same flaw, and the fix is the same
one: route the write path through the shape-preserving variant too, so there is
exactly one removal behaviour rather than two to choose between.

The collapsing variants are **deleted**, not deprecated. They were unused after
the change, and the entire bug family came from having two behaviours available
and picking the wrong one — leaving the wrong one lying around is an invitation
to pick it again.

What found this was not a new test but a new *script*. `scripts/verify_collection.sh`
codifies these end-to-end checks the way the project's other `verify_*` scripts
do, and because it binds twice to check idempotency, it exercised an ordering no
hand-run check had. That is the point worth keeping: **the manual verification had
been thorough and still missed it, because the steps had never been run in that
order.** A script is not just a convenience — it is a different, and sometimes
better, adversary than the person who wrote the code.

### The toggle that was implemented as a re-registration

Every fix above lives in `JXCodeCore`, and the GUI reaches it through `AppState`.
That seam is the one layer with no tests — `JXCodeCoreTests` depends on
`JXCodeCore` only, so no `AppState` code is covered by anything. Auditing it for
stray writes turned up something better than a stray write.

Skills toggled correctly. Connectors did not. The reason is visible in the two
implementations side by side:

```swift
func setSkillEnabled(id: String, enabled: Bool) {
    try sharedStore.setSkillEnabled(id: id, enabled: enabled)   // a setter
    refreshShared()
}

func setConnectorEnabled(id: String, enabled: Bool) {
    var connector = sharedConnectors[index]
    connector.enabled = enabled
    addConnector(connector)                                     // a re-add
}
```

`addConnector` is a *registration* method, and it does two things a setter must
not. It **validates** — so a connector with an empty `command` could never be
switched **off**, which is the one action that would stop it being bound. And it
reports `"Registered \(name)."`, so every toggle claimed to have just registered
the connector it was switching. Automations had the same re-add routing, minus the
guard, so they got the wrong message and no dead end.

The dead end is the interesting half, because it is exactly inverted: an
incomplete connector is already refused at bind time, and that part is right —

```
broken: refused — broken has no command. A local connector needs one to start.
```

— so the row showed a refusal *and* a switch, and the switch did nothing. The user
could see the problem and had no way to act on it. `enabled` is their field: it
records whether they want the connector bound, not whether it is well-formed.
Validation belongs at bind time, where it already is.

Reproduced before fixing, with an in-run **control** rather than a bare assertion:

```
                       before the fix    after the fix
good   (valid)         enabled=False     enabled=False
broken (invalid)       enabled=True  ←   enabled=False
```

Toggling both in one launch is what makes this evidence. Without the `good` row,
"`broken` did not change" is equally consistent with *the guard blocked it* and
with *the hook never ran* — the two explanations this whole exercise was meant to
tell apart. The control is what turned a coincidence into a cause.

The fix is to give `SharedStore` the setter it was missing —
`setConnectorEnabled` and `setAutomationEnabled`, mirroring the `setSkillEnabled`
that was there all along — and point `AppState` at them. Six tests now cover the
store's toggles, including that an invalid connector is still switchable off
*while* the binder still refuses to bind it.

The general shape, and it is the same one as the rest of this section: **a setter
is not a re-add.** When two of three sibling sections share a design and the third
does not, the odd one out is usually the bug — skills had the setter, and skills
were the section that worked.

### The colour that was readable as a tint and not as a fill

[The theme](#the-theme) exists because two screenshots were sampled into a
palette, and sampling one colour produced two constants. The amber is used in the
reference as a *fill* with dark text on it. In this app it had also been used as a
*foreground* — as an icon tint, as a low-opacity wash — and those are different
requirements: `#FEB43B` is legible on a dark surface and nearly invisible on a
white one.

Splitting it into `accent` (foreground) and `accentFill` + `accentOn` (fill) is
correct, and it is also the kind of change that breaks a call site silently. So
every existing use of `Theme.accent` was audited for whether it was a tint or a
fill. About fifteen call sites were tints and needed nothing. One was a fill:

```swift
// SharedTabButton, the selected section in the shared pane
.background(Theme.accent)          // a fill
.foregroundStyle(.white)           // white text on amber
```

White on `#FEB43B` fails contrast in both modes. It did not show up before the
redesign because `accent` was then a *dark* colour — the constant had been
serving both roles by accident, and it only worked because the fill was dark
enough for white text. Making the foreground amber legible is precisely what
turned a working call site into a broken one.

The lesson is not "audit your call sites". It is that **a constant named for one
role will be used in another**, and the rename that fixes it (`accent` →
`accentFill`) is the moment every use has to be re-read. Sampling a palette from
two screenshots is easy; finding the one call site that depended on the old
ambiguity is the actual work.

### The launcher that could not see the tool it was offering to launch

The Tools grid has to answer "is `herdr` installed?", and the first answer was
wrong in an instructive way: it read the app's own `PATH`.

A GUI app launched from Finder inherits a minimal `PATH` — `/usr/bin:/bin:
/usr/sbin:/sbin` — and none of `~/.local/bin`, `/opt/homebrew/bin` or
`/usr/local/bin`. So the check reported **not found** for a tool the user runs
every day from their shell. The failure is not that the lookup missed; it is that
it *looked authoritative*. A card saying `not found` about an installed tool
reads as "JXCode is broken", not as "JXCode did not look in the right place".

The fix is a fixed directory list rather than `PATH`. The interesting part is that
the sandbox lookup must **not** be changed the same way: it reads the sandbox
`PATH`, because that is the `PATH` an agent will actually get, and "resolvable
here" is the only thing that makes `Launch` honest. Two lookups, two sources,
deliberately:

```swift
if let inSandbox = ExecutableResolver.resolve(tool.binary, environment: environment) {
    return .sandbox(inSandbox)                             // the agent's PATH
}
for directory in hostSearchDirectories(home: hostHome) {    // a fixed list
    …
    return .host(candidate.path)
}
```

Collapsing them is wrong in both directions. Sandbox-only would report "not
installed" for a daily tool; host-only would find the host binary and launch it —
which is the leak the whole app exists to prevent. And on this machine both tools
land in the second branch, correctly: `~/.local/bin/herdr` is the *user's* home,
while `SandboxPaths.localBin` is `<sandbox>/home/.local/bin`. Same relative path,
different home — so `Mac only` is the honest answer, and it is the one the card
shows.

### The palette only some of the app was using

The redesign replaced `Theme` wholesale, and then an audit asked the question a
redesign always leaves open: **did the new palette reach every surface?** It had
not. A sweep for SwiftUI's own palette colours turned up twenty-odd call sites
using `.orange`, `.green`, `.teal`, `.blue`, `.gray` and `.white` directly.

The most instructive were the status foregrounds:

| | light | dark |
|---|---|---|
| `.orange` on a card | **2.18** | 8.55 |
| `.green` on a card | **2.20** | 8.70 |
| `.teal` on a card | **2.55** | 8.84 |

Every one passes comfortably in dark mode and fails badly in light. That is why
they survived: the app was **pinned dark** when they were written, so they were
never wrong. Making the palette adaptive is what turned them into defects — the
same change that fixed the app created them.

The obvious fix, swapping `.orange` for `Theme.warning`, is half a fix, and the
measurements say so:

```
.orange        → 2.18          the bug
Theme.warning  → 3.86          the swap — still below 4.5
                → 5.81          after darkening by the smallest passing factor
```

The sampled warning was itself below AA, and the app also draws it on a 14% wash
of itself (3.29:1). So each light status colour was darkened by the smallest
factor clearing 4.5:1 on **every** surface and **every** wash the app actually
uses — 0.78× `warning`, 0.80× `success`, 0.89× `danger` — keeping the palette as
close to the reference as legibility allows.

The other finding was `IconTile`, which drew its glyph in white over a fill from
the hashed dot ramp. White is 1.81:1 on `tileAmber`, 2.61:1 on `tileOrange` and
2.90:1 on `tileGreen` — all under the 3:1 floor for a non-text graphic — and 3.34
to 4.71:1 on the other four, which want white. So the ink is now chosen by the
requirement itself:

```swift
static func ink(on fill: UInt32) -> UInt32 {
    contrastRatio(inkLight, fill) >= minimumGraphicContrast ? inkLight : inkDark
}
```

Thresholding on **luminance** instead is the shortcut that looks right and is
wrong: the gap between `tileGreen` (0.3124) and `tileBlue` (0.2646) is narrow and
sits between two dots needing *opposite* inks, so a luminance cutoff would have
to be tuned. Testing the ratio tests the thing.

Both rules now live in `Palette` (`JXCodeCore`) rather than `Theme`, because the
app target has no test target and an unenforceable rule is a comment. 21 tests,
and they were shown to have teeth before being trusted: reinstating the sampled
`warning` fails 6, making the ink always white fails 7, and reinstating the
sampled `textSecondary` fails 1 — with the precise failure message reading
*`4.4996:1, below 4.5:1`*, which is the knife edge the audit was meant to catch.

A third leak the audit found was `.secondary` itself — SwiftUI's
`secondaryLabel` semantic colour. **53 call sites** bypassed `Theme` for it,
which is a different kind of leak: not a colour that fails, but a colour that
fails *and* contradicts the palette. Measured against `Theme`'s surfaces:

```
                    light card    page
SwiftUI .secondary    3.41          3.18        FAILS AA body text
Theme.textSecondary   5.51          4.4996      *right on the line*
```

Two problems at once: the system colour is sub-AA in light mode (and it is a
*cold grey*, `#8A8A8E`, sitting in a palette that is explicitly warm), and the
theme's own secondary was sitting at **4.4996** on the page — one ten-thousandth
under AA, technically passing only by rounding. So both moved:

- `Theme.textSecondary` light `#6B6862` → `#686660` (0.976×), now 4.65:1 worst.
- All 53 `.secondary` call sites → `.foregroundStyle(Theme.textSecondary)`.

`Theme.textTertiary` failed the **graphic** floor (2.92:1 on a card — it is used
for unselected icons and idle dots), so it moved too: light `#9A968E` →
`#84807A` (0.856×), dark `#6E6E73` → `#717176`. That tier is now held to the
graphic floor rather than the text floor, on purpose: it is the inactive tier,
not for informational body text.

A fourth leak was hiding in plain sight: the memory bar's four segments were
**the identity `Tile` colours** — `blue`, `teal`, `purple`, `orange` — reused
directly as chart fills. At the bar's `.opacity(0.75)` and composited over a
light surface, they land at:

```
segment          card    elevated   page
Weights (blue)   2.37    2.20       2.08
KV cache (teal)  2.43    2.25       2.13
Projector (purple) 2.99  2.77       2.62
Compute (orange) 2.04    1.88       1.78
```

All four below the 3:1 graphic floor on every surface. An identity dot carries
its own ink, so it can afford to be faint; a bar segment has only the surface
behind it, so it cannot. `purple` failed in *both* modes — the only one — so
the dark half of the new ramp is also not simply the tiles.

The first solve cleared the floor by darkening each to the minimum. That fails
in a quieter way: every segment lands on the same luminance (separation ≈1.00),
because the floor is what sets luminance. The bar reads as one colour to anyone
who cannot use hue. The rule has to govern both — `minimumGraphicContrast` vs
the surface *and* `minimumSegmentSeparation` between adjacent pairs — and the
view has to draw at the alpha the rule is computed for, so the rendered colour
and the asserted colour are the same thing. `Palette.chartSegmentAlpha = 0.75`
makes that binding single-sourced; the segments now read `Palette.chartSegmentAlpha`
rather than the literal `0.75`.

The chart ramp then becomes a search over per-segment scaling factors with both
constraints, optimised to stay closest to the sampled hue. Light darkens by
~0.50–0.70×, dark barely moves (purple is the only one that had to lighten).
Six tests cover the new rule and pin the values it replaced: every tile
`usedAsSegments` is asserted to fail the graphic floor in light mode at the
governed alpha, so reinstating any of them as a chart fill fails the suite.
The separation test has teeth proven by a deliberate mutation — the
floor-only solve (`#39629A`, `#2E696E`, `#6E4FA8`, `#984B3D`) passes every
surface-contrast test and fails separation at 1.01 / 1.00 / 1.00.

Verified on the dashboard for regression. The memory bar itself sits behind a
model-selection flow that needs accessibility permission to drive, so this fix
is verified by rule rather than by pixels — the suite and the binding alpha
are what hold it.

A fifth leak was the one the previous fixes could not catch: **opacity on a
governed colour invalidates the rule**, because the rule asserts the value at
alpha 1.0 and `.opacity(0.6)` compositing into the surface is what the user
actually sees. Two cases were live:

`textTertiary` was drawn at `.opacity(0.6)` in six places — every one of them
a *graphic*, not text (status dots, inactive-state icons in `MXIconView`).
The composite lands at **1.89–2.12:1** on every light surface, below the 3:1
graphic floor: the inactive state was barely visible. The fix was to drop the
opacity: `textTertiary` at 1.0 already clears 3.18, and the visual hierarchy
(active = success green, inactive = grey) is preserved by *hue*, not by
faintness. A negative test pins the broken composite so the `.opacity(0.6)`
does not return — a rule that accepted it would not be a rule.

`Theme.accent` itself was the deeper case. Measured:

```
                              light card    page
Theme.accent foreground         5.05         4.13     sub-AA on page
Theme.accent on accent@0.14     4.19         3.48     sub-AA on every wash
```

The wash case is the binding constraint, and the problem is structural: a tint
of the foreground over a light surface is necessarily close to the foreground
in luminance, so lightening the wash makes it *worse* (3.48 → 3.67 → 3.75 as
alpha goes 0.14 → 0.10 → 0.08). The only way to clear 4.5 on a wash is to
darken the foreground itself. `Theme.accent` light `#9A6200` → `#805100`
(0.83×), now 5.50 worst on a surface and 4.53 worst on its own wash — both
clear AA with margin. Dark accent was unchanged (already 6.42+ on every wash).

The negative test pins the sampled value's two specific failures (page at
4.13, wash over page at 3.48). It deliberately does *not* assert the sampled
fails on every surface — it passes on `card` (5.05), so a blanket negative
would be wrong. The rule is the binding constraint, not the whole rule.

The final audit sweep found four stragglers: `.tertiary` (one text site,
1.04–2.10 in both modes — same shape as `.secondary` was), `.primary` (one
text site, passes at 17+), and three `.white` icon tints on tiles (pass on
the tiles they sit on, but a future tile change could break them silently).
The `.tertiary` site was replaced with `Theme.textSecondary` (4:65 worst).
The `.primary` site became `Theme.textPrimary` for consistency. The three
icon tints became `Theme.ink(on: <tile>)` — the rule-driven ink choice, so
a future tile change picks the right ink automatically rather than
trusting the developer's luck.

To make all of this hold, `AuditLintTests` walks `Sources/JXCodeApp/` at
test time and fails on any `SwiftUI` semantic colour in a colour position
(`.foregroundStyle(`, `.fill(`, `.tint:`, etc.). A second narrower test
catches `MXIconView(name:, size:, tint: .white)` specifically. The audit's
22 sites across five rounds would all have failed this test at PR time —
turning a manual sweep into a CI guard. Mutation-proven: reinstating
`.foregroundStyle(.orange)` fails the suite with the exact file:line.

---

## Roadmap

### Pillar 02 — done

Register a backend, fetch its models, pick one, route every agent at it. See
[Model routing](#model-routing).

- `ProviderKind` covers OpenAI-compatible, native Anthropic, Ollama and
  (for pillar 03) local GGUF, each with its own endpoint paths and auth scheme.
- `ModelCatalog` handles four different model-list envelopes, and falls back to
  the root path when a server does not use a `/v1` prefix.
- `ModelRouter` serves the four endpoints above with translation in both
  directions.
- `AgentConfigWriter` binds the agents, sandbox-only and merge-first.

Also in this pillar, since the first draft of it:

- **Provider keys are editable after creation.** The pencil on a provider row
  opens the same fields used to add one, and the key is written back to
  `providers.json`.
- **Per-agent model overrides.** Each agent can be pinned to a different model
  than the routed default; the override is written into that agent's own config
  rather than into a shared one.
- **The router has an access token.** Off by default, because the previous
  behaviour is the same trust boundary as a local Ollama. When enabled the
  router fails *closed* — an empty token rejects everything rather than
  accepting everything — and compares in constant time, so a token cannot be
  recovered by timing. `jxcode auth` prints it; agents bound by this app are
  rewritten with it automatically.
- **`/props` is proxied.** An agent can now ask the router what the loaded model
  actually is, which is the only way for it to learn the real context window
  rather than the one it assumed.
- **SSE keep-alive.** Claude Code aborts a stream after 300 s of silence. The
  router now emits an Anthropic `event: ping` every 15 s of upstream silence,
  and — the part that is easy to get wrong — it starts counting *before* the
  upstream request, because prefill is the longest silence in the whole
  exchange. An earlier version started pings only after the first upstream byte
  and would have aborted on exactly the slow requests it was written for.

### Pillar 03 — done

Read a GGUF file's own metadata, pair it with its vision projector, and derive
the `llama-server` invocation from the hardware present. See
[Local models](#local-models).

- `GGUFReader` parses the container with a bounded, non-materialising walk.
- `GGUFModelInfo` interprets it, handling architecture-scoped keys and the
  KV-cache arithmetic.
- `ProjectorNameMatcher` / `ModelScanner` handle all four real mmproj naming
  conventions, extensionless files, symlinks and orphan projectors.
- `HardwareProfile` reads `sysctl` for memory and the performance/efficiency
  core split.
- `ModelOptimizer` produces an explained argument list from two explicit
  policies.
- `LlamaRuntimeLocator` and `LlamaServer` find and supervise the binary.
- The CLI (`scan`, `model-info`, `llama-plan`, `runtime`, `serve`) and the
  SwiftUI Models pane are two views over the same `ModelReport` / `AppState`
  code, so they cannot disagree.

Also in this pillar, since the first draft of it:

- **The runtime can be installed into the sandbox.** `LlamaRuntimeInstaller`
  has two methods and prefers the first: *adopt* the host binary by copying it
  and its whole dylib closure into the private prefix, or generate a build
  script when there is no host copy. Adoption is not a file copy — the Homebrew
  `llama-server` is a 42 KB launcher that links eight libraries out of
  `/opt/homebrew`, so the install names are rewritten with `install_name_tool`
  and the result is re-signed, because Apple Silicon refuses to execute a
  modified Mach-O whose signature no longer matches. It stages into a temporary
  directory and verifies the copy runs *before* installing it, so a failure
  leaves the existing runtime untouched. Verified against the real binary: the
  adopted copy reports build 10150 and initialises Metal.
- **The chat template is resolved rather than hoped for.** llama.cpp ships 56
  built-in templates (`chatml`, `llama3`, `gemma`, `phi4`, `deepseek2`, …).
  `ChatTemplateLibrary` maps a model's architecture onto the right one, so a
  model that embeds no template and matches no default is still served with a
  format tool calling can parse. `llama` is the interesting case: it is
  ambiguous between Llama 2 and Llama 3, and the only thing in the header that
  distinguishes them is the vocabulary size — which is why the GGUF reader now
  records array *lengths* even when it skips their contents.
- **Sampling is explicit.** llama.cpp's defaults (temperature 0.8, top-k 40)
  are tuned for chat; a coding agent that samples a tool call at 0.8
  occasionally emits prose where JSON was expected. Three presets — agent,
  balanced, creative — are emitted as flags so the behaviour is visible in the
  plan rather than implied by an upstream default that may change.
- **`--reasoning-format` is set for thinking models**, so reasoning tokens
  arrive in a field the clients understand instead of leaking into the reply.
- **MoE models get a different compute buffer.** A mixture-of-experts model
  activates a fraction of its weights per token, so the 1/12-of-weights rule of
  thumb over-allocates badly; those get 1/24.
- **The running server is asked to confirm the plan.** `ServerProps` reads
  llama-server's own `/props`, which reports what it *actually* loaded:
  `chat_template_caps`, `modalities`, the real `n_ctx`, and the slot count.
  Everything else about the template is a prediction made from a GGUF header;
  this is the one thing that can contradict it. `RealLlamaServerTests` starts a
  real server from a real plan and asserts the two agree — including when the
  prediction is *negative*.
- **A template that cannot call tools is caught before launch.**
  `ChatTemplateLibrary` prefers the model's own template, which is right in
  general and wrong in one specific case: a model whose author never wrote tool
  handling into it. A real example on this machine is a 1.1B model carrying a
  410-character template of plain `<|user|>` / `<|assistant|>` tags. Nothing
  about that file looks broken, llama.cpp accepts it, and the model then answers
  in prose when an agent asks for a tool. The plan now says so up front, and the
  Models pane shows a warning rather than letting you find out mid-conversation.

### Known limitations

- **Not Mac App Store distributable.** A sandboxed terminal that spawns
  arbitrary CLIs is incompatible with App Sandbox. Developer ID + notarisation
  is the realistic path.
- **`getpwuid` fallback** — see above. Mitigated for the agents that matter, not
  closed in general.
- **No VM mode.** Isolated by convention and environment rather than by the
  kernel. A tool that ignores `$HOME` *and* has no config-dir override is not
  contained.
- **The router's token is off by default.** It can be enabled, and when enabled
  it is enforced properly (fail-closed, constant-time comparison), but the
  shipped default is still "any process on this machine that can reach the port
  can use your API keys". That is the same trust boundary as a local Ollama or
  LM Studio, and it is the right default for a single-user machine — but it is a
  choice, not an oversight, and `jxcode auth --enable` is one command away.
- **The local model server is unauthenticated too.** `llama-server` is started
  with `--host 127.0.0.1` and no API key, so any process on the machine can use
  a loaded model. Same trust boundary as the router, stated for the same reason.
- **A served model is stopped when the pane closes.** Deliberate — an orphaned
  `llama-server` holds gigabytes — but it means you cannot load a model, close
  the window, and keep using it from an agent.
- **`--load-mode` is only emitted for the `maximal` policy.** A `safe` or
  `balanced` plan leaves loading on llama.cpp's `mmap` default, which is the
  right answer when the model is sharing the machine but does mean a long-idle
  model can be compressed and has to fault back in.
- **The tool-calling prediction is a text search.** It looks for the `tools`
  variable or the `tool_calls` / `tool_call_id` fields a template must read to
  emit a structured call. That is a heuristic, not an evaluation, and it is
  deliberately biased towards "supported": warning about a model that works is
  worse than staying quiet about one that does not, because the authoritative
  answer comes from the running server's `/props` anyway. A template that
  mentions tools in a branch it never takes will be read as capable.
- **Unbinding leaves empty directories behind.** The file rule — remove what we
  created rather than leave it — stops at directories, and that is a decision
  rather than an oversight. For a file, `*.jxcode-backup` is a reliable record
  that the file predated JXCode; a directory has no equivalent, so "empty now"
  is not the same as "we made it", and deleting a directory the user already had
  is a change they did not ask for. It also matters less: a leftover empty
  `.config/opencode/` or `.claude/skills/` changes nothing an agent *parses*,
  which is the harm the file rule exists to prevent. The two that survive a full
  bind-and-unbind cycle are `.claude/skills/` (the container for skill symlinks)
  and `.config/opencode/`. If you would rather they went, the shape of the fix
  is a `dirExisted` check in the writers plus a conditional removal in `revert` —
  cheap, but it needs its own ownership record first, which is the whole reason
  the file rule works.
- **JSON configs come back semantically, not byte for byte.** Text files
  (`config.toml`, `AGENTS.md`, `GEMINI.md`, `CLAUDE.md`) are returned exactly as
  they were found, including blank lines and the trailing newline. JSON is not:
  `settings.json` is re-rendered on every write, so a compact
  `{"zeta":1,"alpha":2}` comes back pretty-printed with sorted keys. The content
  is identical — the same object, key for key — but the bytes are not, and a
  diff will show it. Closing this would mean a format-preserving JSON editor
  (a lossless CST with position tracking rather than `JSONSerialization`), which
  is a large amount of machinery for a file whose meaning survives the round
  trip intact. Stated here so the byte-for-byte claim above is not read as
  covering more than it does.
