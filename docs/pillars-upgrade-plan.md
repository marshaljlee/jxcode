# JXCode — pillar upgrade plan

Three pillars, researched against primary sources rather than blog posts, then
turned into an ordered set of upgrades. Every claim about an upstream binary was
checked against the binary installed on this machine; where a blog and the
binary disagreed, the binary won and the disagreement is recorded.

The rule for the whole plan: each item lands in `JXCodeCore`, is exposed through
both the `jxcode` CLI and the SwiftUI pane over the same code, gets tests, and
records in the README what the naive version gets wrong.

---

## Sources checked

- **llama.cpp / `llama-server`** — the `--help` of the build installed here,
  read directly, plus the server's own `/props` and `/health` output from a live
  run. Release notes were used only to find *what* to look for.
- **agentskills.io** and the Agent Skills specification — for the on-disk
  format, the frontmatter fields, and the discovery rules.
- Each agent's own documentation and, where it exists, its source — for the
  config paths and file formats the shared collection has to write.
- **Anthropic Messages** and **OpenAI Responses** wire documentation — for the
  event set and block types the router has to carry.
- **`apple/containerization`** and **`apple/container`** — for the isolation
  question, which is deferred rather than designed here.
- **llama-swap** — as a model to adopt, not a binary to depend on.

---

# Pillar 1 — Local GGUF

## What changed upstream

`llama-server` is no longer "an OpenAI-compatible endpoint with a few flags".
Three shifts matter:

1. **The flag surface grew a tuning layer that did not exist before.** KV cache
   reuse across requests (`--cache-reuse`), a RAM ceiling for the cache
   (`--cache-ram`), per-slot cache thresholds (`-sps`), unified per-slot
   context (`--kv-unified-per-slot`), prompt-cache persistence
   (`--slot-save-path`), a full sampler chain that can be emitted explicitly
   (`--samplers`, `--sampler-seq`), MoE expert placement (`-cmoe`, `-ncmoe`),
   and a self-fitting mode (`--fit`, `-fitt`, `-fitc`).

2. **Reasoning became a first-class, controllable thing** rather than a
   template quirk: `--reasoning-effort`, `--reasoning-budget`,
   `--reasoning-preserve`, `--reasoning-format`, and
   `--chat-template-kwargs` to pass template-level switches such as
   `enable_thinking`.

3. **The server speaks more than one wire.** Anthropic Messages
   (`/v1/messages`, `/v1/messages/count_tokens`) and OpenAI Responses
   (`/v1/responses`) are served natively, not translated. That changes the
   router's job for a local backend from "translate" to "forward".

## Where jxcode stands (verified in `ModelOptimizer.swift`)

The planner is good and conservative where it counts. It gets the two arguments
that are correctness rather than tuning — `--parallel 1`, because `-c` is the
total across slots; and `-t` counting performance cores only, because the
generation loop is latency-bound. It reads `/props` back and compares it to the
plan, which most tools do not.

Three gaps:

- **The tool-calling answer is a text search.** `ChatTemplateLibrary` looks for
  the `tools` variable and the `tool_calls` fields. It is biased towards
  "supported" on purpose, and it is still an inference about a format.
- **The flag set is the older one.** None of the reuse, reasoning, MoE-placement
  or `--fit` levers are emitted, so plans leave real performance and real
  context on the table. *(Closed by 1.2 below — and the second half of the gap
  was that the levers that were emitted had no gate, so they could take an older
  server down.)*
- **A served model dies with the pane.** Deliberate — an orphaned `llama-server`
  holds gigabytes — but it is a UX problem with a known shape (llama-swap), not
  a technical one.

## Upgrades

### 1.1 Replace the tool-calling heuristic with a live probe — **landed**

`ToolProbe` in `JXCodeCore`, `jxcode probe <base-url>`, the Models pane's
*Tool calling, observed* section, and 18 tests in `ToolProbeTests`. Verified
against a real 15.2 GB Qwen3.5 MoE on `llama-server` 0.4.1: `/props` reports
`supports_tools: true, supports_tool_calls: true` and the probe reports
`✓ verified — the model called echo`. Six verdicts, not two, so an
inconclusive probe cannot be read as a refusal; exit code 0 only for
`verified`. The static prediction is kept as the pre-launch warning and shown
beside the observation.

`ChatTemplateLibrary` currently predicts tool support with a text search, and
the README admits it is biased towards "supported". Now there is a better
answer available before the user ever talks to the model: after launch, send a
one-message request with a trivial tool and assert a `tool_call` comes back.
llama.cpp does JSON-Schema → GBNF → PEG, so the probe exercises the real path.

- **Where**: new `ToolProbe` in `JXCodeCore`; surfaced in `ModelReport` and the
  Models pane as *verified* vs *predicted*.
- **Why**: this converts jxcode's weakest known limitation into its strongest
  claim. "We asked the model to call a tool and it did" beats any header parse.
- **Keep** the static prediction as the pre-launch warning; demote it once the
  probe has run.

### 1.2 Emit the modern flag set — **landed**

Each new flag is an `LlamaArgument` with a one-line `reason` like every existing
one, and each is **gated on the binary's own `--help`** rather than assumed.
That gate is the whole point of the item: emitting a flag a build does not define
is not a harmless no-op, it is `error: unknown argument` and llama-server exits at
startup — a failure that reads as a bug in this app rather than a version
mismatch. `LlamaServerCapabilities.defines(_:)` is the general form of the
per-flag probes that already existed for `--flash-attn` and `--load-mode`.

| Flag | This build's default | Why it is emitted |
| --- | --- | --- |
| `--cache-reuse 256` | 0 (off) | KV shifting reuse; an agent's transcript is append-only, so prefill is where the seconds go |
| `--cache-prompt` | enabled | stated because `--cache-reuse` is a no-op without it — the binary's help says "requires prompt caching to be enabled" |
| `--cache-ram N` | 8192 | derived from what the plan leaves free, instead of a flat 8192 MiB on every machine |
| `--jinja` | enabled | **not** emitted by the planner; `ChatTemplateLibrary` already carries it with a better reason |
| `--chat-template-kwargs` | — | only on a build with **no** `--reasoning`, where it is the only lever for `enable_thinking` |
| `--reasoning-format deepseek` | auto | keeps the model's reasoning out of the answer and in its own field |
| `-rea on` | auto | the trace is mapped onto an Anthropic `thinking` block rather than left to template detection |
| `--reasoning-budget -1` | -1 | stated so the plan shows the agent's own `max_tokens` is the only limit |
| `--reasoning-preserve` | template default | an agent resends the whole transcript every turn; dropping earlier traces changes the prompt between turns |
| `--samplers <chain>` | `penalties;dry;top_n_sigma;top_k;typ_p;top_p;min_p;xtc;temperature` | `--samplers` replaces the whole chain, so naming it is what stops a preset depending on that default |
| `-ncmoe N` | — | the one working partial-offload lever, for a MoE that does not fit; N derived from the excess, not a fixed fraction |
| `--fit on` | on | stated because "the server may trim what we did not specify" is a fact about this command line a reader should not have to infer |

#### Flags the original table named that this build does not have

Checked against `llama-server --help` for build 10150 (commit `dee2a846b`):

| Named in the plan | Reality |
| --- | --- |
| `--reasoning-effort` | **zero occurrences** in the help text. The knob does not exist; the plan's "map thinking onto the real knob" was mapping onto nothing. |
| `-sps 0.10` | Exists, and the default is already 0.10 — nothing to tie to `--parallel`, nothing to do. |
| `--kv-unified-per-slot N` | `-kvu`/`--kv-unified` is a **boolean**, not a value, and its default is already right. |
| `--context-shift` "default on" | **Default disabled.** The plan said on, which inverts the reason for emitting it: jxcode emitting it is load-bearing, not decorative. |
| `--fit` as a cross-check | `--fit` adjusts only arguments left **unset**; it cannot overrule `-ngl` or `-c`, which the plan always sets. So it is neither the authority nor the cross-check — it fills gaps, and the cross-check is `/props`, which `testPropsAgreesWithWhatThePlanPredicted` already does. |
| `--slot-save-path` | Exists; left out. Persisting the prompt cache needs a lifecycle decision about where those files live and when they are collected, which belongs to 1.3 rather than here. |

#### Five defects only a live render could find

The gates were correct and the unit tests were green, and the printed plan was
still wrong in five ways. All five were found by rendering a plan for a real
model against the real binary and reading it:

1. **`--jinja` printed twice.** The planner emitted it and the template
   resolution already had. Both arguments were well formed and the flag was
   present, so no assertion on presence could have caught it — the test is on the
   *count*.
2. **`--cache-ram 8192` beside a reason claiming to depart from 8192.** The
   derivation clamps to llama.cpp's default when the headroom exceeds it, and the
   reason was written for the case where it does not. Fixed by emitting only a
   value that is strictly inside the open range — see (5).
3. **`--samplers penalties;top_k;top_p;temperature` went out unquoted.** The
   rendered command, pasted into a shell, ran `penalties` and then `top_k` and
   `top_p` and `temperature` as four separate commands. `shellQuoted` tested for
   space, quote and backslash and left every other metacharacter bare; it is now
   an allowlist, so the failure mode of the set being too small is a redundant
   pair of quotes rather than a command that does something else.
4. **`--reasoning-format` was the one member of its group with no gate** — the
   single flag the planner would hand to a build that cannot parse it. Its three
   siblings were all gated; it was missed because it is emitted first.
5. **`--cache-ram 0`.** When the model does not fit, the derivation lands on 0 —
   and `0` is not a small bound in this flag's vocabulary, it is `disable`. The
   plan would have enabled prompt caching with one flag and given it no memory
   with the next, quietly defeating the `--cache-reuse` that depends on it. A
   derivation that lands on the sentinel cannot be expressed with this flag, so
   it is not spelled with it.

#### `--chat-template-kwargs` is deprecated where `--reasoning` exists

The build says so out loud at startup:

```
W Setting 'enable_thinking' via --chat-template-kwargs is deprecated.
  Use --reasoning on / --reasoning off instead.
```

That is a claim about behaviour, so it was tested as one: two servers, one
variable between them, same model and prompt.

```
without kwargs   block types: ['thinking']   deprecation: (none)
with kwargs      block types: ['thinking']   deprecation: W Setting 'enable_thinking' …
```

Both reason. The kwarg adds a warning and nothing else, so on a build with
`--reasoning` the planner suppresses it and `-rea on` is the mechanism. It is
kept for the builds where it is the *only* lever: `--chat-template-kwargs` with
no `--reasoning`.

#### Where the capabilities come from

A gate is only worth something if real capabilities reach the planner, and they
did not: `probe` was `async`, the planner is not, so every plan was built against
`.assumedModern` and every gate stood permanently open. Fixed by splitting the
probe into a synchronous body (it always was synchronous — two pipes and a
semaphore) with `probe` as a thin `async` wrapper, and memoising it on the
binary's path, size and modification date so the Models pane does not launch a
`llama-server --help` per keystroke on a policy slider.
`LlamaRuntimeLocator.capabilities()` is the bridge, and both the CLI and the
pane go through it so the terminal and the window cannot plan against different
capability sets.

`LlamaServerCapabilities.adapt` gained the same list as a second line of defence.
The planner gates what the *plan* claims; `adapt` decides what the *process* is
given, and `default:` there passes anything unrecognised straight through — so
without it a plan built against the assumed capabilities would take a whole
server down on an older build. The duplication is deliberate and the two answer
the same question from opposite sides.

#### Two behaviours deliberately left as llama.cpp's

`--parallel 1` and `-t` counting performance cores only are unchanged. Both are
correctness rather than tuning: `-c` is the total across slots, and the generation
loop is latency-bound. Nothing here touches them.

#### Verified

`testTheRealBinaryDefinesEveryFlagThePlannerGatesOn` asserts each gated name is a
flag this build actually defines — the check that would have caught
`--reasoning-effort`. `testTheModernFlagSetSurvivesTheRealBinary` builds a plan
for a thinking MoE that does not fit, asserts every modern flag the planner
emitted is still in the argv the server is given, and runs that argv against the
real binary with `--help` expecting exit 0. `ModernFlagTests` holds 41 tests over
the gates in both directions, the five defects above, the shell quoting, and the
adapter's second line of defence.

`--context-shift` is still a valid flag in this build, and its default is
**disabled** — so jxcode emitting it is what makes a session outliving its context
work at all.

### 1.3 Model lifecycle, llama-swap style — **landed**

The known limitation — "a served model is stopped when the pane closes" — is
the thing llama-swap exists to solve, and it is a UX problem, not a technical
one. Adopt the model, not the binary:

- **On-demand load**: first request for a model starts it, using its saved
  `OptimizationPlan`. No "serve" button required.
- **Idle TTL unload**: configurable; never orphan gigabytes.
- **Aliases**: agents ask for `coder` or `vision`; the router maps to a real
  file. Cheap, and it makes per-agent overrides readable.
- **Profiles**: swap which model serves an alias without touching agent config.
- **Live log streams**: proxy log, upstream log, HTTP log, per-model log —
  split the way llama-swap does, because one mixed stream is unreadable.
- **`/health` and `/metrics`** surface in the Models pane.

**Where**: `LlamaServerSupervisor` + `RunningServers`, `ModelReport`,
Models pane, `jxcode serve` / new `jxcode models` commands.

**Cost.** Not the supervisor. The first landing was five files in
`Sources/JXCodeCore` — no CLI, no pane, no tests, no README entry, the plan doc
still unmarked — and **it did not compile**: two string literals nested one
level too deep, where Swift cannot parse a literal inside an interpolation
inside the literal it is interpolating, and its `unterminated string literal`
complaint names the wrong line. So the track began by repairing the build, and
what the live run then found was three fabrications and two error cases that
could not fire. See `## What landed` below.

## What landed

The design above is what was built, with two additions and four corrections the
live run forced.

**Aliases and profiles, in one file.** `ModelLifecycleStore` holds
`state/models.json` — a fifth state file, not a section of `providers.json`,
because a provider is *where a backend is* and an alias is *what a name means*,
and the two change on different clocks. Folding them together would make every
profile switch rewrite the file holding the API keys. `setAlias` upserts on the
*folded* name, so `Coder` replaces `coder` rather than sitting beside it.

**The supervisor, attached to the router rather than folded into it.**
`LlamaServerSupervisor` implements `LocalModelServing`, and `RouterState` holds
it in a slot of its own. `RouterConfiguration` is compared with `==` to decide
whether a running listener still matches what the UI shows; a live object with
no stable value in that comparison would make every attach read as "the
configuration changed". `AppState` attaches it in `init()` — and until this
track finished, **nothing did**, so the router's whole alias path was
unreachable and a request for `coder` fell through to the configured model,
silently, which is exactly what a name the router has never heard of gets.

**Four streams, and the fourth one had to be built.** `proxy` is the router's
decision log, `http` is a second `RouterLog` the router writes before it decides
anything, and `model` is per alias under `logs/models/`. `upstream` was the
problem: `ModelLogs.prepare` created the file and nothing ever wrote to it, so
the stream was an empty file under a heading promising every server's output.
`Process` takes one `standardOutput`, so a new `LogTee` fans the child's output
out through a pipe into both files. Verified live — byte-identical, 1140 bytes
each.

**The idle timeout is reported as measured, not as configured.** The sweep runs
on its own interval, so a 10-second threshold is acted on up to 40 seconds
later. The CLI printed the threshold as though it were the elapsed time. It now
prints `32s idle, threshold 10s`.

### What the plan got wrong

- **"`jxcode serve` / new `jxcode models` commands."** `models` was already
  taken by the backend probe, and the core's own error messages already said
  `jxcode local` — three of them, naming a command that did not exist. The
  command is `jxcode local`, and the messages are now true.
- **The count of aliases is not what makes this useful; the *file check* is.**
  `ModelLifecycleError.missingModel` was declared with a written argument that
  an alias "is only worth binding to a model that is on disk" and was never
  thrown by anything. It is now enforced in `setAlias`, which also stores the
  path expanded and standardised — `~` is expanded by a shell and by nothing
  else, and this string is read by an agent's config loader and a JSON decoder.
- **`ModelLifecycleError.unknownAlias` was dead on arrival.** It duplicated
  `ModelServingError.unknownAlias`, which carries the list of names that would
  have worked. Deleted. `removeAlias` returns `false` for a name that was not
  bound, which is the right ergonomics for an unbind and cannot also throw.
- **`uses: 1` was hardcoded in `launch`.** Right on the router path, where the
  load was caused by a request; false on `start(alias:)`, where a person asked
  for a model to look at it — so `jxcode local serve` reported `1 request` for a
  server that had answered none. The count is now threaded from the caller.

### Verified against the binary

**There are two llama.cpp builds on this machine and the app runs the one this
document does not name.** `/opt/homebrew/bin/llama-server` — the first host
entry `LlamaRuntimeLocator` searches — is a symlink to
`Cellar/llama.cpp/0.4.1`, which reports **build 10964**. `Cellar/llama.cpp/10150`
is also installed, and the "Verified against the binary on this machine" section
below is written against it.

Both `--help` texts were compared: all fifteen flags the planner gates on
(`--chat-template-kwargs`, `--fit`, `-ncmoe`, `--cache-prompt`, `--cache-reuse`,
`--cache-ram`, `--reasoning-format`, `-rea`, `--reasoning-budget`,
`--reasoning-preserve`, `--samplers`, `--metrics`, `--jinja`, `--reasoning`,
`--context-shift`) exist in both. That is what the capability probe is for: the
gates are read from the binary at run time, so a second build is safe rather
than fatal. The disagreement is recorded rather than resolved, because the
binary the app launches is 10964 and the document says 10150.

Live, against `MiniCPM5-2B.gguf` on build 10964: `jxcode local alias` →
`jxcode local serve` loaded the model on demand, answered `/health` 200,
answered `/metrics` 200 with a real Prometheus body (`--metrics` was emitted
because the build defines it), wrote both log files, and unloaded itself on the
idle sweep — `32s idle, threshold 10s`.


### 1.4 Decide: delegate multi-model to llama-server router mode, or not — **landed**

`--models-dir` / `--models-max` gives multi-model local serving for free. It is
tempting and it conflicts with jxcode's own `ModelRouter`, which also fronts
remote providers. Recommendation: **do not delegate**. Keep one router so
per-agent overrides, auth, and the activation chain stay in one place. Revisit
only if local-only multi-model becomes a real workflow.

**Cost.** The decision was already made; the *mechanism* was wrong. This section
read as though `--models-dir` switches router mode on, which would make "do not
delegate" a rule about not passing a flag. Measured against the installed binary
it is not: router mode is what the server falls back to when **no model is
named**, and the flags only configure it. The track's real work was turning a
negative rule about a flag into a positive rule about a model, and giving that
rule a refusal with a reason.

### What landed

- `ModelServingPolicy` in `JXCodeCore` — `ModelServingMode` (`.oneModel(path:)`,
  `.router`, `.malformed`), `mode(of:)` (the check, and it is a check about a
  *model*, not about a flag), the decision text both surfaces print, the refusal
  reason, and the four router flags with what each one does.
- `LlamaServerConfiguration.mode` and `.configuredRouterFlags`, both read from
  the plan's own argument list rather than from a stored setting.
- `LlamaServer.start()` **refuses rather than launches** when the plan names no
  model: `LlamaServerError.noModelNamed(mode:)`, carrying the reason.
- `jxcode local policy` — the decision, the router flags the located binary
  actually defines, and what jxcode does instead.
- A Models-pane section, "One model per server", gated on the report being
  non-empty.
- 19 tests in `ModelServingPolicyTests`.

### What the plan got wrong

**The mechanism.** Four runs on build 10150, `--host 127.0.0.1`, no model file in
sight:

    llama-server                                        -> router mode, 0 models
    llama-server --models-max 2                         -> router mode, 0 models
    llama-server -m /nonexistent.gguf                   -> not router mode; exits
    llama-server -m /nonexistent.gguf --models-dir D    -> not router mode; exits

Router mode is not switched on by `--models-dir`. It is what the binary does when
no model is named, and the `--models-*` flags only *configure* it — beside a `-m`
they are inert, which is the third and fourth run above. So the rule that keeps
llama-server out of router mode is the positive one: **every server this app
starts is given exactly one `-m`**.

**The flag count.** This section names two flags. Both `--help` pages on this
machine define four — `--models-dir`, `--models-preset`, `--models-max`,
`--models-autoload`, plus the `--no-models-autoload` twin — under the heading
"for the router server".

**Why it has teeth.** A model-less server answers `/health` **200** immediately,
with its own log saying `Available models (0)` in the same second, and `/props`
answering `role: "router"`, `model_path: "none"`, `n_ctx: 0`. `LlamaServer.start()`
confirms a launch by polling `/health`, so such a server is declared healthy while
holding nothing — the one failure that check cannot see. The refusal exists
because of that measurement, not because a flag was passed.

### Verified by hand

`jxcode local policy` against a throwaway `JXCODE_ROOT` prints the decision, then
the four router flags the located binary defines (all four read as `defined`),
then what jxcode does instead and how to bind two models at once. Exit 0. The pane
renders the same string — it is one report, not two.


### 1.5 What makes this user-friendly

- One "Good" plan and one "Advanced" drawer. Every flag still carries its
  `reason`; the default path must require zero decisions.
- Show the *predicted* memory breakdown and then the *actual* `/props` readout
  side by side. That contrast is jxcode's signature move; keep it.
- Never let a plan claim something the server contradicts. `/props` wins.

---

# Pillar 2 — Router and translation

## What changed upstream

**Anthropic wire** now carries: `thinking` blocks with `signature_delta`
(integrity check, sent just before `content_block_stop`), `input_json_delta`
partial-JSON tool args, `server_tool_use` and `web_search_tool_result` blocks,
`fallback` blocks emitted at model boundaries, cumulative usage in
`message_delta` including `cache_creation_input_tokens` and
`cache_read_input_tokens`, `ping` and `error` events inside the stream,
date-versioned tool types (`web_search_20250305`), and — under
`thinking-binding-controls-2026-08-01` — an `input_transformations` array on
`message_start` and the final `message_delta`.

**OpenAI Responses** carries `reasoning` items whose `encrypted_content` is
opted in via `include: ["reasoning.encrypted_content"]` (required for stateless
multi-turn and for zero-data-retention orgs), `function_call` items with both
`call_id` and `id`, `strict` per-tool validation, assistant messages tagged
with `phase: commentary | final_answer`, plus `background`, `conversation`,
`context_management`, `truncation`, `previous_response_id`, `service_tier`.

**llama-server** now accepts Anthropic and Responses wire directly.

## Where jxcode stands

`ModelRouter` serves four endpoints with translation both ways, has an
access token that fails closed, proxies `/props`, and emits an Anthropic
`event: ping` every 15 s of upstream silence, counting from *before* the
upstream request. That last detail is better than most proxies get.

## Upgrades

### 2.1 Stop translating when you don't have to — **landed**

If the backend is llama-server, proxy `/v1/messages` straight through. Native
speakers beat translation: no thinking-block round-trip, no tool-id mapping, no
usage remapping, no drift. Keep the translator for OpenAI-only backends
(Ollama, vLLM, LM Studio, remote OpenAI-compatible).

- **Where**: `Provider.kind` gains a wire capability; `ModelRouter` chooses
  passthrough vs translate per provider.
- **Risk**: two code paths. Mitigate with the existing pattern — one fixture
  corpus asserted against both.

**The premise is verified, not assumed.** The routes are in the server
implementation itself, read out of the installed binary rather than taken from
release notes:

```
$ strings -a "…/env/brew/lib/libllama-server-impl.dylib" | grep -E "^/v1/"
/v1/chat/completions      /v1/messages        /v1/responses
/v1/completions           /v1/messages/count_tokens
/v1/embeddings            /v1/models          /v1/rerank
```

Three consequences, in order of how much they change the work:

1. **`/v1/messages` is real**, so `localGGUF` can take the Anthropic wire
   directly and the whole translation path is skipped for the one backend most
   likely to be carrying a thinking model.
2. **`/v1/messages/count_tokens` is real too**, which retires part of 2.3 — the
   `count_tokens` estimate exists because no backend could answer it, and this
   one can.
3. **`/v1/responses` is real**, which is worth knowing before 2.2 invests in
   widening the Responses translation.

One correction to the note above: the installed libraries are
`libllama-*.0.0.10150.dylib`, not the `10964` this plan was written against.
The route table was read from the libraries actually on this machine, so it is
evidence about what is installed — but a passthrough must still be checked
against a *running* server before it is trusted, because a compiled-in route is
not the same claim as a working one.

## What landed

**The route is a URL, not a flag.** `ProviderKind.messagesPath` returns `nil`
for a backend with no Anthropic endpoint and the path for one that has it, and
`requiresTranslation` is *derived* from it rather than restated. A boolean beside
a path can disagree with it, and the disagreement is a request body posted to an
endpoint that does not speak it — which is the failure this whole change exists
to avoid. `Provider.messagesURL` resolves it; `speaksOpenAI` is the second,
separate fact the fallback needs.

**`localGGUF` keeps `chatPath` as `{base}/chat/completions`** and gains
`messagesPath` of `{base}/messages` — not `{base}/v1/messages`. A bare
`host:port` is normalised to carry `/v1` for this kind, so repeating the prefix
would produce `/v1/v1/messages`, exactly as `chatPath` once did. Anthropic
refuses the automatic prefix, so its path carries its own.

**The one trap the plan named, closed.** The passthrough branches used to post to
`provider.chatURL`. For `localGGUF` that is the OpenAI path, so an Anthropic body
would have landed on `/chat/completions` and come back a 400 that said nothing
about the real mistake. Both branches now take the messages URL, and
`testTheMessagesRouteIsSeparateFromTheChatRoute` asserts the two are never equal.

## The find: a passthrough that re-encodes is not a passthrough

The first implementation kept the existing shape — decode into
`AnthropicRequest`, re-encode, send — and moved the URL. That is wrong, and
wrong in the direction that matters, because `AnthropicRequest` is deliberately a
*partial* model: it declares the fields the router has to understand and drops
everything else on the way back out.

| Dropped on re-encode | Consequence |
| --- | --- |
| `cache_control`, on a system block or a tool definition | prompt caching stops working; the user pays and is not told |
| `signature` on a `thinking` block | Anthropic requires it back on the next turn, so a thinking conversation breaks on turn two |
| the payload of any block type it does not model | `redacted_thinking` carries its content in `data`; `.unknown` re-encodes as a bare `{"type": …}` |
| every top-level field added after the struct was written | `context_management`, `anthropic_beta`, … |

A lossy passthrough is **strictly worse than the translation it replaced**: the
same losses, plus a promise that there are none. So the native route now parses
the client's body as a generic `JSONValue` tree, replaces one key, and
re-serialises with everything else intact — and when the model name does not
change, which is the common case for an agent bound to this router, the original
bytes are forwarded without even a parse.

`testTheDecodedRequestIsNotAFaithfulCarrierOfTheClientBody` is the tripwire: it
asserts the struct *is* lossy, so if it ever becomes faithful that test fails and
the raw-body path can be reconsidered rather than quietly kept.

## The fallback: a version table would have been a guess

A compiled-in route is not a working one. An older llama-server build has no
`/v1/messages`, and without a fallback every Claude Code turn against it becomes
a 404 — a regression from the translation that used to work.

The route is therefore **asked, not predicted**: a 404 or 405 from the messages
endpoint raises `MissingRoute`, which is its own type precisely because it is the
only upstream failure the router can route around. Everything else — 400, 401,
429, 500 — is the backend's verdict on a request it *did* understand, and
answering it with a second request in another shape turns one error into two and
discards the first. `MissingRoute` carries a `description` matching the message it
replaced, so raising a type changed no byte of what a client is told.

The streaming case is why the passthrough checks the upstream's status *before*
forwarding a frame: the response head is already sent, so a fallback that ran
after the first frame would splice a translated stream onto the tail of a native
one. Checked before, the client sees one coherent stream and never learns there
was a second attempt.

Anthropic itself is never fallen back from — it has no OpenAI route, so a retry
would post a translated body to `/v1/messages`. `speaksOpenAI` is what draws that
line.

## Verified against a running server

```
POST /v1/messages  (system block with cache_control, metadata, anthropic_beta)
  → 200  {"type":"message","content":[{"type":"thinking",…},{"type":"text","text":"banana"}]}
streaming → message_start, content_block_start, content_block_delta × n, … message_stop
```

`RealRouterChainTests.testAnAnthropicRequestIsServedNativelyByARealLlamaServer`
now asserts this on the router's *own account* of the request — `wire=native`
present, `does not serve` absent — because the reply alone cannot tell a native
answer from a good translation of one. Without that assertion the older chain test
would keep passing if llama-server stopped serving the route tomorrow, and nobody
would notice the translation had quietly come back.

## A recorded asymmetry

The translator echoes the alias the client asked for; the native route hands back
the backend's own reply, so the name in it is the backend's — on this machine,
the full model path. That is how the Anthropic passthrough already behaved before
this change. Making the two agree means editing a body the router promised not to
touch, which belongs with 2.2 rather than smuggled in here.
`testTheTwoRoutesReportTheModelNameDifferently` records it so it stays a decision.

### 2.2 Widen translation to the current event set — **landed**

Add, in priority order:

1. **Reasoning round-trip** — Anthropic `thinking` + `signature` ↔ Responses
   `reasoning` + `encrypted_content`. Without this, a thinking model loses its
   trace every time an OpenAI-shaped client is involved.
2. **`call_id` vs `tool_use` id** — Responses carries both; preserve the
   mapping so multi-turn tool results still match.
3. **`server_tool_use` and `web_search_tool_result`** — pass them through
   rather than dropping them, so a client that asked for a server tool is not
   silently answered without one.
4. **`fallback` blocks** — an Anthropic client that receives one has been told
   the model changed mid-answer; swallowing it turns a documented signal into a
   mystery.
5. **`error` events inside the stream** — a stream that fails after headers has
   no status code to carry the failure, so the event is the only place it can
   be reported.

## What landed

**The design rule this track settled on: a translation reports every block it
cannot carry, by name, and the block model is lossless for anything it does not
interpret.** The request direction had always built those notes. Nothing read
them — every call site discarded them — and the response direction had no notes
channel at all, so a `fallback` block was dropped by a `default:` arm that said
nothing to anyone. Both halves now report, and the router writes what they say
to its log and keeps the latest set for the pane.

Underneath that, `AnthropicContentBlock` stopped being lossy by construction. It
decodes through `JSONValue` now, so a block whose `type` it does not model keeps
**every** field it arrived with. Before, the keyed decoder could only re-emit the
names in `CodingKeys`, so `redacted_thinking` — which carries its content in
`data` and nothing else — came back as a bare `{"type":"redacted_thinking"}`.
That is not a lossy copy of a block, it is a different block.

### Three things the plan got wrong

All three checked against the installed binary rather than against a document.

**`signature_delta` is real, and the plan puts it in the wrong place.** The plan
says it is "sent just before `content_block_stop`". Build 10150 sends it
immediately *after* `content_block_start`, before any thinking delta:

```
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":""}}
```

**The `↔ Responses` half of priority 1 has no wire to happen on.** jxcode
translates to OpenAI **Chat Completions**, not to Responses, and the Chat
Completions wire has no signature field — verified against a running server:
the Anthropic wire returns a thinking block carrying `signature`, and the OpenAI
wire returns `reasoning_content` with no signature anywhere in the body. So
there is no round trip for a signature to survive, and the router must not
fabricate one: an empty `signature` is not a neutral value, it asserts an
integrity check over the trace that nobody performed. The translated path
therefore reports the signature as dropped, and the buffered thinking block it
builds carries no signature rather than an empty one.

**"Pass them through" is only available on one of the two routes.**
`server_tool_use` and `web_search_tool_result` do pass through untouched on the
Anthropic→Anthropic route — but 2.1 already made that route a byte-level
passthrough, so there was nothing to add. On the translating route there is no
OpenAI block to pass them into, and the honest maximum is to name them. That is
what landed.

### What landed, concretely

- `AnthropicContentBlock.thinking` carries its `signature`; `unknown` carries its
  whole object.
- Drop notes name the block *types*, sorted, so the same conversation always
  produces the same sentence. `1 thinking block(s) dropped` keeps its own
  sentence, because it is the one loss that is not a formatting detail.
- `AnthropicTranslationResult` and `TranslatedResponse` are the reverse- and
  response-direction notes channels, mirroring `TranslationResult`.
- Orphan `tool_result` handling in **both** directions. Reverse: a `tool` message
  with no `tool_call_id` used to become `"tool_use_id": ""`, a block Anthropic
  refuses; it is now matched to the only candidate when there is exactly one, and
  dropped and named otherwise. Forward: a `tool_result` naming a `tool_use` the
  transcript never declared is now named.
- `Translation.streamError(inChunk:)` and `AnthropicSSE.error(_:)`: an upstream
  error frame inside a stream becomes an Anthropic `event: error` and **no**
  `message_stop`.
- `RouterLog.lastTranslation` / `writeTranslation(_:route:)`, a card in the
  Providers pane, and `jxcode translate --direction … [--response]`.

### Four defects only real output found

**The 2.1 tripwire fired, which is what it was for.**
`testTheDecodedRequestIsNotAFaithfulCarrierOfTheClientBody` asserts that
`AnthropicRequest` is lossy, so that a passthrough promising fidelity cannot
quietly route through it. Teaching the block model to keep a signature made the
decoded request faithful in one more respect, and the test went red on exactly
that line. The reconsideration it demanded was made, and the answer is to keep
the raw-body path: `cache_control`, `anthropic_beta` and `context_management` are
still dropped. The assertion is now *positive* on the signature, so a regression
is caught here rather than only in the translator's tests.

**The buffered response lost the model's reasoning; the streamed one kept it.**
`jxcode translate reply.json --response` printed a body with `content` and no
`reasoning_content` at all. `OpenAIMessage.encode` deliberately refused to write
the field, on the reasoning that echoing a chain of thought back to a model is
unwanted in a multi-turn conversation — true for a *request*, and this type is
also the body of a *response*. The streamed path was unaffected because
`openAISSEFrames` builds its deltas through `JSONValue` and never touched that
encoder, so the same answer kept its reasoning when streamed and lost it when
fetched whole. The rule moved to where it belongs: `Translation.request` never
puts reasoning on a message it builds, asserted directly, and the wire type
encodes what it holds.

**The CLI's label column was one character too narrow.** `input tokens` is twelve
characters and the column was twelve wide, so the line read `input tokens≈58`.
Only reading the printed output shows that.

**A `tool_result` naming a `tool_use` the transcript never declares printed no
note at all.** The orphan check existed in the reverse direction only, and the
first hand-run body happened to contain exactly that inconsistency.

### Recorded, not fixed

The Anthropic wire's `usage` carries `cache_read_input_tokens` and
`cache_creation_input_tokens` — verified live, the reply above reports both.
`AnthropicUsage` models neither, so `Translation.openAIResponse` cannot tell an
OpenAI-shaped client about cache reads. That is a change to the usage model
rather than to the event set, and it belongs with 2.4's streaming hygiene.

### Verified live

`RealRouterChainTests.testTheTranslatedRouteReportsWhatItCannotCarryToARealModel`
drives a real router in front of a real llama-server declared `openAICompatible`
— which is what forces the translator, since 2.1 means a `localGGUF` provider
never reaches it — sends a body carrying a `server_tool_use` and a `thinking`
block, and asserts a 200, that both types are named, and that the notes reached
the log the pane reads. By hand: `jxcode translate` in all three modes, against a
reply captured from the running server.

### 2.3 Use real token counts when they exist — **landed**

`/v1/messages/count_tokens` was estimated. llama-server serves the real thing at
the same path, so for a local backend the estimate can be replaced by a
measurement — and the estimate kept only as the fallback for backends that have
no endpoint.

**Landed.** The route still answers `{"input_tokens": N}` and nothing else; what
changed is where the `N` comes from, and that the router now knows which of the
two it gave.

#### The measurement, against a running server

```
POST /v1/messages/count_tokens  {"messages":[{"role":"user","content":"Hello, how are you today?"}]}
  → {"input_tokens":18}                      estimate says 11

POST /v1/messages/count_tokens  (system prompt + one tool schema, one user line)
  → {"input_tokens":213}                     estimate says 70
```

The shape is Anthropic's own, so the reply is forwarded unchanged rather than
re-encoded. Also measured, and each one shaped a decision:

| Probe | Answer | What it settled |
|---|---|---|
| thinking + `tool_use` + `tool_result` body | `200`, 68 tokens | the full Claude Code payload is accepted; `thinking` blocks are counted |
| `{"model":"does-not-exist"}` | `200`, 12 tokens | the model field is not validated, so the router need not rewrite it |
| `{"messages":[]}` | `200`, 6 tokens | the template floor is non-zero — the estimator's `max(total, 1)` is not the same answer |
| an unknown path under `/v1/messages/` | `404` | absence is *observable*, which is what makes the fallback a fact rather than a guess |

#### Where the estimate is wrong, and how wrong

The estimate counts the characters it can see, so it cannot see the chat
template. On a tool-bearing request the schema dominates and the estimate is low
by roughly a factor of three — in the one direction `TokenEstimator`'s own
comment calls dangerous, because a client told it has more room than it does
overflows instead of compacting. That is now the measured-versus-estimated
distinction the log carries, and the reason this was worth doing rather than
merely tidy.

#### Four decisions the plan did not anticipate

1. **The counting endpoint is derived from `messagesPath`, not restated.** A
   backend that serves the Anthropic wire serves the counting endpoint beside
   it, and the capability *is* the URL — the same idiom `messagesURL` already
   uses, so a kind cannot claim a count it has no path for.
2. **The estimate is not deleted, and the fallback is silent.** vLLM, LM Studio
   and OpenRouter have no counting endpoint. A 404 or 405 is remembered per
   backend (`TokenCountCapability`, keyed on the normalised base URL — the same
   identity `ProviderStore.add` collapses on), so a backend that cannot count is
   asked once rather than once per turn. A timeout is *not* remembered: that
   means the server was busy, not that it cannot count.
3. **Counting got its own `URLSession`.** The shared one has a 600-second
   request timeout, chosen because a local model producing a long answer takes
   minutes. That value is exactly wrong for a number asked for on the way into
   every turn — a backend that had gone away would hold the turn for ten minutes
   before the estimate could stand in. `countingTimeout` is 3 seconds.
4. **Provenance goes to the log, not the body.** This is Anthropic's endpoint
   and a client is entitled to Anthropic's shape, so the reply carries
   `input_tokens` and nothing else; `(measured)` or `(estimated)` is written to
   the router log the pane already reads. `jxcode route`'s banner gained a
   `count` line beside `translation`, so the operator learns which answer they
   will get before the first turn.

#### One rule kept from the estimator

A count of zero is refused rather than reported, on either path. A client told
it has used no context believes it has unlimited room, which is worse than a
slightly wrong positive number. A reply that is not the expected shape — a
string, a negative, an Anthropic-shaped 404 body returned with a 200 — is `nil`
and the estimate stands in.

#### Verified

`RealRouterChainTests.testATokenCountIsMeasuredByARealLlamaServer` starts a real
llama-server from the app's own plan, points a real router at it, and asserts
both halves that matter: the count is positive, and it is **not** what the
estimator would have said — without the second assertion the test would pass on
the estimate it exists to have replaced. `jxcode route`'s banner was read by
hand. 21 tests added; the suite is 1317, 0 failures, 1 skip.

### 2.4 Streaming hygiene — **landed**

- The `ping` timer must reset on *any* upstream byte, not only on a parsed
  event, or a large `input_json_delta` looks like silence.
- A `message_delta` carrying cumulative usage must not be double-counted.
- Reassembly must be byte-safe: a chunk boundary inside a multi-byte character
  is normal, not an error. There is already a `UTF8BoundaryTests` for the same
  trap elsewhere; the streaming path needs the same treatment.

## What landed

**Two of the three bullets were already true, and the track's real work was to
find that out and pin it.** That is the honest report. The per-byte deadline
reset has been in `StreamKeepAlive` since the router's first commit, and the
byte-safe reassembly was settled by review item 12 (`ea44044`), which is why
three boundary tests already existed. Nothing here rewrote either. What did not
exist was a test that would fail if one regressed — and "the code is correct" and
"the code is correct and stays correct" are different claims, and only the second
one is worth a track.

The third bullet was the one with something in it, and the trap is a *future*
refactor rather than a present bug. `message_delta`'s usage is cumulative, and
the event's name reads like an increment, so `reportedUsage = usage` becoming
`reportedUsage += usage` would look like a fix. It is now pinned by a test that
feeds three cumulative usage chunks and asserts the last, not their sum — which
matters because Claude Code's context accounting decides when to compact from
that number, so an inflated count makes it compact early and then keep
compacting.

### The one thing the binary settled

llama-server's own streamed `message_delta` carries **only** `output_tokens` —
verified against a running server, not read out of a document:

```
event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":37}}
```

The router's *translated* route emits `input_tokens` there as well, because the
real prompt count arrives in the OpenAI usage trailer — after `message_start` has
already gone out carrying an estimate. That asymmetry is recorded rather than
removed. The field is cumulative like every other usage field, so a client that
reads the last value gets the right answer on both routes; dropping it would
leave the translated route reporting a guess forever. What the binary disagrees
about is the *shape*, and a route that translates cannot promise the upstream's
byte layout.

A second asymmetry, same run. The native `message_start` reports
`{"cache_read_input_tokens":18,"input_tokens":1}` for a request whose buffered
form reports `{"input_tokens":19,"cache_read_input_tokens":0}`. The total is 19
either way, so `input_tokens` on the streaming wire is the *uncached* part, not
the whole. The translated route has no cache information at all — the OpenAI wire
carries none — so it reports the total in `input_tokens` and no cache field. Two
routes, two readings of one field name. Recorded, not reconciled: reconciling
would mean inventing a cache split the OpenAI wire never sent.

### What the live verification showed

`StreamHygieneTests` drives a real socket. `FakeUpstream` gained `streamPieces`
and `dripDelay`, which let a test decide where the chunk boundaries go — the
whole-frame fakes could not reach any of these traps.

- A single 500-byte frame split into eight pieces 100 ms apart, against a 250 ms
  keep-alive interval: **no ping at all**, and the frame arrives intact. The test
  takes 1.0 s, and that number is the evidence — a run where the pieces had
  coalesced into one burst would pass for the wrong reason in 0.05 s.
- One frame, then 900 ms of nothing: a ping, and no ping after `message_stop`.
- A four-byte scalar cut across two upstream chunks, on both the native and the
  translated route. These are cuts the *network* chooses, which is what makes
  them ordinary; the three existing boundary tests cover a cut the router
  chooses.

### 2.5 Per-agent wire, not just per-agent model

Two agents can want different wires from the same router. The override
therefore has to name the wire as well as the model, or a client that speaks
Responses and a client that speaks Messages cannot both be served from one
provider entry.

### 2.6 What makes this effective — **landed**

- One `jxcode prove` that drives a real request through the router and asserts
  what the backend received — the same move `jxcode prove` already makes for
  the sandbox.
- A fixture corpus asserted against both the passthrough and the translating
  path, so a fix on one side cannot silently break the other.

## What landed

**The rule: assert what the backend received, not what the client got.** A router
that translates when it should proxy returns a perfectly good Anthropic answer,
so every check written from the client's side passes on both routes — which is
why 2.1 needed a log line to be testable at all, and why a log line is a weak
witness. `RouteProof` puts a recording server where the backend would be and
reads the other end of the wire.

- `SpyUpstream` is a real listener on loopback, not a `URLSession` stub: the
  route decision is a decision about a *path on a socket*, and a fake at the
  session layer would answer a question about the router's intent. It answers
  **by path** — Anthropic's shape for `/v1/messages`, OpenAI's for anything else
  — which is the same distinction `ProviderKind.chatPath` makes, and is what lets
  one spy serve every route.
- `RouteCorpus` is one list, in the core, driving both the suite and
  `jxcode prove route`. A command with private fixtures would be evidence about a
  different corpus than the one the tests guard.
- Three routes, one corpus: `localGGUF` and `anthropic` (both native, with
  different auth headers) and `openAICompatible` (translated). A fix on one side
  cannot silently break the other — which is the plan's own second bullet, and is
  only true if one list feeds both.
- 122 checks. Per fixture: that the backend was reached **exactly once**, on the
  path the route promises, with the auth header the kind promises, with the
  configured model and not the client's, with the tool definition in the target
  wire's vocabulary, and with the usage trailer where the route translates — and
  that the client got a well-formed, uncorrupted, correctly bracketed Anthropic
  answer.

### The check that earns its place

**"The backend was reached exactly once."** Every other check in the list passes
on a router that gave up on the native route and translated instead. The client
cannot tell — the fallback answers 200 with a good message — and neither can the
path check, because the *first* request did go to `/v1/messages`. The count is
the only witness, and it is asserted as a count rather than as "a request
arrived" for exactly that reason.

The negative control proves it. `SpyUpstream.messagesRouteStatus = 404` is not a
contrived failure: it is what a llama-server build predating the Anthropic route
answers, and the router's fallback exists for it. Against that backend the proof
reports one failure per fixture — all four of them the count — while every other
check passes. A proof that has never been seen to fail is a proof that might be
passing for no reason.

### Two defects, both in the proof itself

**Its reader had the CRLF bug the router is guarded against.** `eventNames(in:)`
split the transcript on `"\n"`. In a CRLF stream CR+LF is a single grapheme
cluster, so `split(separator: "\n")` finds nothing to split on and returns the
*whole transcript* as one element: `first` and `last` were the entire document
and "exactly one `message_stop`" counted zero. Every one of those is a check that
fails on a *correct* router, and it failed on the proof's first run against the
spy — whose stream is deliberately CRLF, the same choice `SSEParser`'s own tests
make. Fixed by splitting on the byte `0x0A`.

**And then the fix was still wrong.** `trimmingCharacters(in: .whitespaces)` does
not remove `\r` — that is in `whitespacesAndNewlines` — so `"message_stop\r"` was
not `"message_stop"` and the count stayed zero. Worse than the first, because the
failure detail printed `last message_stop` while the comparison against
`"message_stop"` was false: a carriage return renders as nothing, so the output
looked correct above a red check. Both are in the README's case study.

### And one found by running the command

The report printed all 122 checks. `jxcode prove` prints all nine of its own, and
that is a screenful; 122 is a wall, and it buries the four lines that matter
under a hundred and eighteen that say "as expected". The default rendering is now
failures-only, with `--all` for the full list. This was invisible in the test
output, where a wall of green ticks reads as success — it was obvious the moment
a real terminal printed it.

### Verified live

`jxcode prove route` in a terminal: 122/122 across the three routes, exit 0, each
route reporting the path it was actually asked for. `jxcode prove route --kind
anthropic`: 40/40 across one route. The pre-existing bare `jxcode prove` still
runs its nine sandbox checks unchanged.

---

# Pillar 3 — Shared collection

## What changed upstream

Skills stopped being a Claude feature and became an **open standard**
(agentskills.io, December 2025, under the Linux Foundation's AAIF, with 32+
tools implementing it). That changes the question from "how do we translate our
collection into each agent's format" to "how do we write the standard format
once and let each agent find it".

The standard's shape:

- A skill is a directory with a `SKILL.md` whose frontmatter carries `name` and
  `description`, and whose body is the instruction.
- Discovery is by directory convention, not by registration.
- **Progressive disclosure** is the point: the `description` is what the agent
  loads to decide whether to read the body, so a vague description makes a
  good skill unusable.

## Where jxcode stands

`SkillBinder` writes a markdown block into each agent's instruction file. That
works everywhere, because an instruction file is read by every agent — but it
means the skill's *body* is in the agent's context from the first token of
every session, which is exactly what progressive disclosure exists to avoid. It
also means one skill cannot be enabled per agent without rewriting the block.

## Upgrades

### 3.1 Make the canonical store spec-valid

`shared/skills/<id>/SKILL.md` already has the right shape. What it lacks is
validation: a `name` that does not match the directory, a missing
`description`, or a description that restates the name. Validate on write and
refuse on read, so a broken skill is caught at authoring time rather than
silently never loading.

**landed** — `SkillSpec` holds the rules taken from the agents' own
documentation rather than from memory. The one design decision worth recording:
`writeSkill` validates the **rendered** text, not the value. `rendered()`
repairs part of the in-memory skill on the way out — it writes the id into
`name:` and always writes a description — so judging the value would refuse
skills whose files are perfectly valid, starting with `jxcode skill-add --name X`
with no `--description`. Judging the bytes is also the only check that can catch
a file edited by hand. `jxcode skill-check` is the read half, and it exits
non-zero, so `skill-check && shared-bind` cannot bind a collection half the
agents will reject.

### 3.2 Bind natively everywhere, keep the markdown block as fallback

Native binding means a symlink into each agent's skill directory, so the agent
does its own discovery and its own progressive disclosure. The markdown block
stays for agents with no skill directory.

### Verified discovery paths (2026-09-27)

| Agent | Skill directory | Notes |
| --- | --- | --- |
| Codex | `$HOME/.agents/skills/` | |
| Gemini | `~/.gemini/skills/` or `~/.agents/skills/` | first activation shows a consent prompt |
| OpenCode | six locations, including `~/.claude/skills/` and `~/.agents/skills/` | **gated by `permission.skill`** in `opencode.json` |
| Claude | `~/.claude/skills/` | `synced` and `anthropic-skills` are reserved names |

Two findings that changed the design:

- **Two symlink targets cover four agents.** `~/.agents/skills/` is read by
  Codex, Gemini and OpenCode; `~/.claude/skills/` is read by Claude and
  OpenCode. Four markdown blocks collapse into two links.
- **OpenCode already reads `~/.claude/skills/` but hides what it finds** unless
  `permission.skill` allows it. So skill binding and connector binding cannot
  be independent passes: writing the link without the permission produces a
  bind that looks applied and does nothing.

### The binding design this implies

- The store stays canonical; every agent's directory holds **symlinks**, never
  copies, so an edit to a skill is live in every agent.
- A `mcp.json`-style ownership record for what was written where, so unbind can
  remove exactly what bind created.
- Reserved names are refused rather than written.
- `permission.skill` is written in the same pass as the link, because one
  without the other is a silent no-op.

**landed** — `SkillBinder.nativeTargets` is the table; `link` runs once per
target and the notes land on every agent that reads that directory. Three
things changed on contact with the real thing:

- **Linking into one directory is not enough.** `~/.agents/skills/` alone
  reaches Codex, Gemini and opencode and misses Claude Code; `~/.claude/skills/`
  alone reaches two. Both links go in, and opencode therefore sees the skill
  twice — last-writer-wins, with a warning. The content is byte-identical
  because both links resolve to the same directory, so the warning is the entire
  cost, and paying it beats leaving an agent without native skills.
- **The permission is not written when the key already exists.** A user who set
  `"*": "deny"` has said something a bind has no business overruling, so that
  case is reported and left exactly as it was.
- **`shared/skills.json` records the one bit the filesystem cannot answer**:
  whether `permission.skill["*"]` is ours. `"*": "allow"` written by the user and
  `"*": "allow"` written by JXCode are the same bytes, so an unbind that keyed
  off the value would revoke a permission it never granted.

A refused skill is bound **nowhere** — not linked, and not listed in the
markdown block either. A bind is a claim that the agent will find the skill, and
making that claim about a file the agent rejects is worse than not binding.

### 3.3 Authoring help that respects progressive disclosure — **landed**

The `description` is the whole interface. An authoring form should say so: a
description that repeats the name is worse than useless, because it costs
context in every session and buys no routing. Suggest, do not enforce — but say
what a good one looks like.

## What landed

`SkillAuthoring` in `JXCodeCore`: three rules, each with a headline, the
mechanism behind it, and a failing/working example pair. Every rule's working
example is the *same* sentence, deliberately — one line satisfies all three, so
an author who writes it has nothing left to check. `rules` is the single source
and both surfaces render it rather than restating it: `jxcode skill-help` prints
the set wrapped to 76 columns, `jxcode skill-add` prints the one rule that
applies to the description it was handed, and the pane shows that same line
under the description field as it is typed with the full set on its tooltip.

Two of the three rules come out of the mechanism rather than a preference. "Keep
it to one sentence" is the description's *cost*: it is in context in every
session of every agent and the body is not, so a paragraph-long description is a
body that is always loaded. "Never leave it empty" is not a style note —
`rendered()` writes the name into an absent description, so empty and
name-identical are the same bytes on disk.

Nothing here refuses anything. The Add button stays enabled and `skill-add`
exits 0 whatever the description is, because the specification constrains
whether a file parses and says nothing about whether a description is any good.

### What the plan got wrong

This section asked for a suggestion surface and nothing else, and the
enforcement it should have been replacing was one function away. 3.1's own note
had already worked out that `writeSkill` must judge the *rendered* bytes
"starting with `jxcode skill-add --name X` and no `--description`" — and stopped
there, without noticing that `findings(for:)` was still judging the value and
still calling that absent description **blocking**.

The enforcement was wrong twice. `Severity.blocking` is defined as "the skill
will not load"; a description-less skill loads everywhere, because `rendered()`
supplies one. And the same skill produced a *blocking* finding from `skill-add`
and an *advisory* from `shared` in one run, because the store reads the name back
out of the file as the description — so the severity depended on whether the
process had restarted. Three commands, three verdicts, one skill.

The file checker had the mirror-image gap. It compared the description against
the frontmatter `name`, which is the **id**, so a description copied from the
body's title was compared against nothing at all — and `# Release checklist`
above `description: Release checklist` is exactly the file `skill-add` writes.
Both checkers now reach the same finding from both directions, and
`testTheTwoCheckersAgreeAboutASkillThatWasJustWritten` is the invariant that
holds them together.

### Verified by hand, not by the suite

Nothing upstream was involved; the evidence is the CLI's own output and a
screenshot of the running app.

- **Before, observed rather than inferred** — the pre-change build was run from a
  stash of this working tree against a throwaway `JXCODE_ROOT`:
  `skill-add --name "Release checklist"` printed `✗ no description` and exited
  `0`; `skill-check` printed `✓ loads everywhere`; `shared-bind` bound it and
  reported `1 linked`. All three, in one run, about one file.
- **After** — all four surfaces print the identical line, and
  `skill-check` now reports the name-shaped description it used to call clean.
- `jxcode skill-help` read as a terminal block: three rules, one worked example
  three times, every line inside 80 columns.
- The pane, from a screenshot at 1100×740: the skill row shows the advisory in
  full and the blocking problem is gone; the form shows `Never leave it empty —
  Use before tagging a release, to run the suite and write the notes` under the
  description field with Add still enabled. `.lineLimit(2)` had been truncating
  the advisory mid-sentence — the detail now wraps, matching the `problem`
  branch above it, which always did.
- **Not verified:** that the form's hint *changes* as text is typed. The CLI
  exercises `SkillAuthoring.hint` on all five inputs (absent, name, slug,
  self-referential, good) and the view does nothing but pass two `@State`
  strings to it, but keystrokes into the form did not land through System Events
  and no screenshot shows it switching. Recorded rather than assumed.

### 3.4 Connectors: one definition, four configs, no secret leakage — **landed**

One connector definition, rendered into each agent's MCP config. Secrets are
referenced, never inlined: a connector that writes an API key into four files
has four places to leak from and four places to rotate.

**Cost.** One run, and the cost was not the translation table — that is four
lines. It was establishing what each agent actually does with a reference, which
is four different answers and only two of them are the same, and then deciding
what to do with the two that cannot carry one. `ConnectorBinder` writes
`environment` and `headers` verbatim, so before this track a connector holding a
token put that token in `~/.claude.json`, `~/.gemini/settings.json`,
`~/.config/opencode/opencode.json` and `~/.codex/config.toml` — four files, four
rotations, and nothing anywhere that said so.

## What landed

`CredentialReference` and `CredentialScan` in `JXCodeCore`, a refusal at write
time, a translation at each writer, and both surfaces over the same code.

**The canonical form is `${NAME}`.** A connector's `environment` and `headers`
values are stored with the shell spelling, which is what Claude Code and Gemini
expand. `{env:NAME}` is accepted on the way in, because that is the form someone
copying from a working opencode config arrives with. A bare `$NAME` is *not*
accepted: `$` followed by letters is prose as often as it is a reference
(`Costs $USD per call` contains one), and a rule that guessed would turn a
literal into a broken reference depending on the sentence.

**Each writer translates; the store does not.** That is the whole of "one
definition, four configs", and it is where the track's real content is:

| Target | `env` | `headers` |
| --- | --- | --- |
| Claude Code | `${NAME}` | `${NAME}` |
| Gemini CLI | `${NAME}` | refused for this agent |
| opencode | `{env:NAME}` | `{env:NAME}` |
| Codex | key omitted | not written |

The Codex omission is the interesting one and it is a *translation*, not a
retreat. TOML expands nothing, so writing `${GITHUB_TOKEN}` there would hand the
server the literal text as its token — a config that reads as though it names
the secret and passes a string that is not it. Leaving the key out is correct:
Codex starts the server with its own environment inherited, so a variable that
is set for Codex is set for the server, and JXCode never writes it down.

The two refusals are per agent, not per collection. A connector Gemini cannot
carry is left out of Gemini's config and still bound into the other three, and
`SharedBind.failures` already counts `.refused`, so `shared-bind` exits non-zero
— a partial bind cannot be mistaken for a complete one.

**A literal secret is refused at write time.** `SharedStore.writeConnector`
throws, `ConnectorBinder.apply` refuses it again for a file that never went
through the front door, and `jxcode shared` reports it. The check is not a
judgement made here: it is the rule Claude Code 2.1.284 applies to a plugin's
MCP header values, read out of the installed binary and ported with its
constants intact, so JXCode refuses exactly what the agent it writes *to* would
object to.

`setConnectorEnabled` deliberately does **not** go through that refusal. A
definition can already hold a secret — written by an older JXCode, or edited by
hand — and the switch that turns it off has to keep working, or the row offers
an action that throws. `persist` is the unjudged write; `writeConnector` is the
judged one. Refusing to write it again is not the same as refusing to let go of
it.

### What the plan got wrong

Two things, and the first is a section that was too short to be wrong.

**"Secrets are referenced, never inlined" reads as one rule and is four.** The
plan treats an agent as having one capability, and the capability differs by
*field*: Gemini expands a reference in its MCP `env` block and documents none
for `headers`, so the same connector is representable in one and not the other.
A writer that asked "can Gemini carry a reference" would get one of the two
answers wrong, and it would get it wrong silently — the header would be written
with the literal text, and the failure would arrive as an authentication error
at the server. The table is keyed on `(target, field)` for that reason.

**The plan expected the naive version to be the *value*, not the *name*.** The
8b note said to look at whether a secret can reach a config file at all, which
is the leak. The second failure mode is worse in one specific way and the plan
never mentions it: writing the reference in a spelling the agent does not expand
produces a file that looks correct everywhere and authenticates with the literal
text `${GITHUB_TOKEN}`. opencode is where this bites — its own documentation
says the shell form is not substituted — and it is why the translation exists
rather than a single canonical string written four times.

**And one thing it got right by accident.** The plan's track 11 note says a
clone inside the sandbox cannot see your SSH keys and that
`SandboxOptions.extraEnv` is how you pass a token through. That is exactly the
mechanism a reference depends on: the name in the config only resolves if the
variable is in the environment the agent runs in, which for JXCode is the
sandbox. `connector-add` now says so at the moment the connector is written
(`jxcode env set NAME=…`), which is the one place the two tracks meet.

### Verified against the binaries

Read out of the installed binaries rather than from documentation, per the
standing rule. Where a document was the only source, it is marked.

- **Claude Code 2.1.284** (`~/.local/share/claude/versions/2.1.284`). Config
  `${VAR}` expansion is named in its own error strings — `compliance taints feed
  config ${VAR} expansion`, `withholding this CLI's Anthropic credentials from
  child processes and config ${VAR} expansion` — and its plugin validator tells
  authors to write a header value as a reference: *"header value looks like a
  literal credential. Everything shipped in a plugin is readable by everyone who
  installs it; reference a sensitive userConfig option (`${user_config.KEY}`) or
  an environment variable (`${VAR}`) instead of committing the value."* The
  credential rule ported into `CredentialScan` is that validator's `Ft(key,
  value)`, with its eight secret shapes, its key pattern, its placeholder list
  and its entropy floor.
- **opencode** (`~/.local/bin/opencode`, 143 MB Bun binary). Its own config
  documentation is embedded in it, and says: *"String values such as header
  tokens support `{env:VAR}` interpolation (and `{file:path}`); the shell-style
  `${VAR}` is not substituted."* The substitution function beside it —
  `text.replace(/\{env:([^}]+)\}/g, (D, n) => (o.env?.[n] ?? process.env[n]) || "")`
  — confirms it, and shows that a missing variable resolves to the empty string
  rather than failing. The documented example is `"headers": { "Authorization":
  "Bearer {env:GITHUB_TOKEN}" }`.
- **Gemini CLI is not installed on this machine**, so its behaviour is taken
  from the vendor's MCP documentation and is the one unverified row in the
  table: expansion in the `env` block only, `$VAR` and `${VAR}`, empty string
  for an undefined variable, and no expansion documented for `headers`. The
  refusal for a referenced header is derived from that silence, which is the
  conservative direction — if the documentation is wrong, the cost is a
  connector left out of Gemini, not a token written into it.
- **Codex is not installed either** — `~/.local/bin/codex` is the unrelated npm
  package `codex@0.2.3`, not the OpenAI CLI, so `AgentRegistry` is detecting an
  impostor. The TOML omission rests on the format rather than on Codex: TOML has
  no string interpolation, which needs no binary to confirm.
- **Found while doing this, recorded rather than fixed:** `tomlBlock` writes no
  `headers` for an HTTP connector at all — the `[mcp_servers.x]` shape it emits
  carries `url` and nothing else. That is a pre-existing gap and it affects
  literal headers too, not just references. The Codex report now says so out
  loud ("headers are not written for Codex — this writer has no field for them,
  so a remote connector reaches Codex unauthenticated") instead of dropping them
  in silence, but whether Codex's config supports headers at all is an open
  question that needs a real Codex install to answer.

### Verified by hand, not by the suite

Against a throwaway `JXCODE_ROOT` in `/tmp`, with two sentinels exported as the
secrets:

- `connector-add --env "GITHUB_TOKEN=ghp_…"` refuses, names
  `environment.GITHUB_TOKEN`, and exits `1`.
- The same connector written as `${GITHUB_TOKEN}` registers, and prints the
  names it needs and the command that sets them.
- `shared-bind` with `GITHUB_TOKEN` and `ACME_TOKEN` set to
  `SENTINEL_DO_NOT_LEAK_…`: **zero files under the sandbox root contain either
  sentinel** — the invariant the track exists for, checked by walking every file
  rather than by reading the four configs.
- The four configs, read back: Claude `"GITHUB_TOKEN": "${GITHUB_TOKEN}"`,
  Gemini the same, opencode `"GITHUB_TOKEN": "{env:GITHUB_TOKEN}"` and
  `"Authorization": "Bearer {env:ACME_TOKEN}"`, Codex a `[mcp_servers.github]`
  table with **no `env` key at all**.
- Gemini refused the remote connector and bound the local one in the same run;
  the refusal is reported once, and the exit code is `1`.
- Hand-editing a stored `connector.json` to hold a literal credential: `shared`
  reports it, `shared-bind` refuses it, and the entry it had already bound is
  **removed** from Claude's, Codex's and opencode's configs.
- The pane, from screenshots at 1100×740: the row for the hand-edited connector
  shows the finding in warning colour with the remedy intact; the row for the
  clean one shows `names GITHUB_TOKEN` under its command; and typing
  `API_KEY=sk-…` into the form raises the finding and **disables Register**,
  while `API_KEY=${API_KEY}` replaces it with the neutral line and re-enables it.

### 3.5 Finish the unbind rule — **landed**

Unbinding must leave behind exactly what it found. Directories are the gap —
see the README's note on empty directories surviving a full bind/unbind cycle,
and on why closing that needs an ownership record rather than an "is it empty"
test.

**Cost.** One run, and the cost was not the ownership record — that was the file
rule extended by about sixty lines. It was *counting the directories*. Four
survived a cycle, not the two the README named, and the two it did not name were
invisible because `createDirectory` makes every missing ancestor and reports
none of them. Then, having counted them, the bind turned out to be the worse
half: an empty collection created three directories and an `opencode.json`
granting a permission, while printing "no shared skills to list".

**What landed.** `ConfigFiles.createDirectory(at:upTo:)` records every missing
ancestor it creates, in `<dir>.jxcode-created` — a sibling of the directory, not
something inside it, because a marker inside would make the directory non-empty
by construction and the emptiness guard could never hold.
`ConfigFiles.removeCreatedDirectories(_:upTo:)` walks *upward* from each
candidate and removes every directory that is both ours and empty; the upward
walk is what takes `.agents/` with `.agents/skills/`.
`SandboxPaths.directoriesABindMayCreate` is the complement of
`requiredDirectories` and names every directory a bind may make. Both binders'
`revert` and `AgentConfigWriter.revert` sweep it, and the record on disk decides
which of them finds anything. Every writer now creates its directory at the
point of writing rather than at the top of the function, so a bind that writes
nothing — or refuses — leaves nothing behind.
`SkillBinder.allowOpencodeSkills` takes the bindable skill list and revokes its
own grant when there is nothing to allow.

**What the plan got wrong.** Two things. The README said two directories survive
a bind/unbind cycle; four did. And it called that a *decision* — "a leftover
empty `.config/opencode/` changes nothing an agent parses" — which was true and
beside the point: the rule this track is named after is that an unbind leaves
behind exactly what it found, and "it does not matter much" is not that. Second,
the track is written as an unbind problem, and the bind was the worse half: an
empty `shared-bind` created directories *and* a permission grant, on a sandbox
that had never held a skill.

**Verified by hand.** A throwaway `JXCODE_ROOT`, bound and unbound through the
CLI: the directory set under `$HOME` is identical before and after, with four
removals named on the way out. Then the same round trip with `.claude/skills` and
`.agents/skills` pre-created by hand — both survive, and `.config/opencode` still
goes. Then with a file added to a directory the bind had made — the directory and
the file survive together. Then with `.claude/skills` symlinked to a real
directory — the links land in the target and the symlink itself survives. And the
pane's Unbind, from a screenshot: the four removals appear in its report list,
because both surfaces call the same two `revert` functions.

**Found and recorded, not fixed.** A *dangling* symlink at a skill directory
makes `shared-bind` fail with a raw `NSCocoaErrorDomain 512` that names the
parent directory rather than the symlink causing it. Confirmed identical on the
pre-change build by stashing and rebuilding, so it is not a regression; it is in
the README's known limitations.

**Also corrected in passing.** `SandboxPaths`' comment on `requiredDirectories`
named `SkillBinder.linkClaudeSkills`, a function that does not exist — the one
that does is `SkillBinder.link`. A comment naming a symbol is a comment the next
reader will act on.

### 3.6 What makes this user-friendly

- Bind once, and say per agent whether it took.
- Show the *effective* state (what the agent will read), not the intended one.
- Never claim a bind succeeded on the strength of having written a file.

---

# Sequencing

1. **1.1 live tool probe** — converts the weakest known limitation into the
   strongest claim, and it is self-contained. **Done.**
2. **3.1 + 3.2** — make the canonical store spec-valid and bind natively into
   `~/.claude/skills/` and `$HOME/.agents/skills/`, with opencode's
   `permission.skill` written in the same pass. Highest correctness-per-line in
   the whole plan. **Done.**
3. **2.1 passthrough** — removes an entire class of translation bugs for the
   local backend. **Done** — including the raw-body rewrite without which it
   would have been worse than the translation, and a fallback for llama-server
   builds that predate the route.
4. **1.2 modern flag set** — mechanical, visible payoff, each flag with its
   reason. **Done** — and not mechanical after all: eleven gates, five defects
   that only a live render exposed, and the capability probe that had to stop
   being `async` before any gate could close.
5. **2.2 reasoning round-trip** — the largest single translation gap. **Done** —
   and the gap was not where this list said it was. The block model was lossy by
   construction, the request-direction notes were built at every call site and
   read by none, and the response direction had no notes channel at all. Three
   claims about the wire in the section above were wrong and the installed binary
   settled all three.
6. **1.3 model lifecycle** — the biggest UX win; do it after the flag set
   settles so plans are stable. **Done** — and the cost was not the supervisor
   but the repair: the first landing was five core files, did not compile, and
   left the router's alias path unwired, the `upstream` log stream empty by
   construction, and two error cases that could never fire.
7. **2.4/2.6 streaming hygiene and `jxcode prove`**. **Done** — two of 2.4's
   three bullets were already true and the track's cost was finding that out and
   pinning them; 2.6 landed as `RouteProof` plus `jxcode prove route`, and its
   first run found two CRLF defects in its own reader.
8. **3.3 authoring help, 3.4 connectors, 3.5 unbind, 1.4/1.5** — five upgrades
   under one number, which is not one run's worth of work. Split on 2026-09-29 so
   each can land whole and the next run has no choice to make:
   - **8a — 3.3 authoring help.** **Done** — and the cost was not the help text.
     It was the enforcement the help had to replace: `findings(for:)` called an
     absent description *blocking*, so `skill-add` printed a blocking finding,
     `skill-check` called the same file clean, and `shared` reported an advisory
     — three verdicts about one skill in one run. The file checker had the
     mirror-image gap and never compared a description against the body's title.
   - **8b — 3.4 connectors: one definition, four configs, no secret leakage.**
     **Done** — and the cost was not the leak, which was easy to see, but the
     *translation*: four agents that do not agree on how to spell a reference,
     and two of them do not agree on whether to expand one at all. Gemini
     expands in its `env` block and documents none for `headers`; opencode uses
     `{env:…}` and explicitly not the shell form; TOML expands nothing, so
     Codex's correct translation is to leave the key out and let the server
     inherit it. The rule that refuses a literal is Claude Code's own, ported
     from the installed binary — and its `${…}` exemption had to be widened,
     because a faithful port refuses opencode's way of naming a secret.
   - **8c — 3.5 finish the unbind rule.** **Done** — and the cost was the count,
     not the code: four directories survived a bind/unbind cycle rather than the
     two the README named, and the bind was the worse half, creating directories
     and an opencode permission grant for a collection with no skills in it. The
     end-to-end script had been calling binding and unbinding inverse operations
     while walking files only; it now walks directories too, and passes.
   - **8d — 1.4 the multi-model decision.** **Done** — and the cost was the
     premise, not the code. The section's recommendation was right but its
     mechanism was wrong: it read as though `--models-dir` switches router mode
     on, when router mode is simply what llama-server falls back to with no model
     named. So the rule is positive — every server gets exactly one `-m` — and it
     is enforced by a refusal in `LlamaServer.start()`, because a model-less
     server answers `/health` 200 while its log says `Available models (0)`.
   - **8e — 1.5 what makes pillar 1 user-friendly.** One Good plan, one Advanced
     drawer, and the predicted-versus-`/props` contrast kept.

Each item keeps the repo's conventions: land in `JXCodeCore`, expose the same
code through both `jxcode` CLI and the SwiftUI pane, add tests, and record in
the README what the naive version gets wrong.

# Added after the first draft

Three items master asked for on top of the eight tracks. They are not
competitive-gap features; they are things the app should already do.

## Track 9 — Make the sandbox environment configurable

`SandboxOptions` already exists with `includeHostLocalBin`, `extraPathEntries`,
`extraEnv`, `routerURL`, `routerToken` — and `SandboxEnvironment` already
applies them. **The core is done; nothing exposes it.** `SandboxOptions()` is
constructed in exactly one place (`main.swift:23`) and everywhere else falls
through to `.default`. That makes this a plumbing job, not a design job:

1. Persist `SandboxOptions` to `sandbox.json` under the sandbox root (mirror
   `AgentRegistry` / `ToolRegistry`: one file, one owner).
2. `AppState` owns the loaded options and hands them to `Sandbox`; the CLI gets
   the same store so the two surfaces cannot disagree.
3. `jxcode env` subcommands: `show`, `set KEY=VALUE`, `unset KEY`,
   `path add/remove`, `reset`. `jxcode env show` reuses
   `SandboxEnvironment.report(workspace:)`, which already prints each PATH entry
   marked `sandbox` or `host`.
4. A pane for it. Editing env is the one place a user can break every agent at
   once, so: validate on entry, and always show the *effective* value — the
   report, not the form.

Guardrail: `extraPathEntries` must go through the same deny-list as
`buildPath()`. An "extra path" that re-admits `/opt/homebrew/bin` defeats the
point of the sandbox, and the deny-list is the whole reason `path_helper` cannot
undo it.

**Status: core + CLI landed.** `SandboxConfiguration` /
`SandboxConfigurationStore` in `JXCodeCore`, 13 tests in
`SandboxConfigurationTests`, six new `jxcode env` options, and `AppState.init`
building the `Sandbox` from the stored configuration. The GUI pane is still to
do.

## Track 10 — Move the plain shell from Agents to Tools

`shell` is registered as an agent (`AgentRegistry.swift:151`) even though it is
not one: `AutomationRunner` refuses it ("is a login shell, not an agent"),
`SkillBinder` refuses it ("reads no instruction file"), `ConnectorBinder`
refuses it ("has no MCP client"), and `ProvidersPane` filters it out by hand
(`$0.id != "shell"`). Four special cases to keep a non-agent out of agent UI is
the smell.

The machinery already exists: `TerminalController.Subject` is
`.agent(AgentDefinition) | .tool(ToolDefinition)` with a `convenience
init(tool:)`, and `AgentPresentation.icon(forTool:)` is a separate table. So:

1. Add `shell` to `ToolCatalog.builtIns` — `binary: "zsh"`,
   `arguments: ["-l"]`, tagline "Plain zsh inside the sandbox".
2. Remove the agent entry and the four special cases.
3. "New Tab" opens the shell by tool id; `AgentPresentation.tagline(for:)`
   loses its `shell` row because tool cards carry their own tagline.
4. Keep `AgentIcons.shell` only if something still renders it; otherwise drop it
   with the rest.

**Status: landed.** All four steps done, seven test files updated, 1057 tests
green. Three intentional `"shell"` references remain, all in the tool path.

## Track 11 — GitHub repo integration

Workspaces are directories today; `Workspace.adopt`/`create` never touch a
remote. Minimum useful version:

1. **Create a workspace from a repo** — `jxcode workspace clone <owner/name>`
   and a sheet in the UI. Prefer `gh repo clone` when `gh` is on PATH, fall back
   to `git clone`.
2. **Show what the workspace is** — `GitStatus` already parses porcelain v2
   including `branch.upstream`; extend it to record the remote URL, derive
   `owner/name`, and surface it on the workspace row with an open-in-browser
   action.
3. **PR / issue state via `gh`** only when it is installed — never guess, never
   fabricate. Absent `gh`, the row shows the repo link and nothing else.

The catch that ties this to track 9: **a clone inside the sandbox cannot see
your SSH keys or your `gh` token**, because `$HOME` is private. Either pass
`SSH_AUTH_SOCK` (and, for `gh`, `GH_TOKEN` / `GH_CONFIG_DIR`) through
`SandboxOptions.extraEnv`, or run the clone on the host and `adopt` the
directory. Recommendation: run the clone on the host and adopt — it keeps
credentials out of the sandbox entirely, which is the whole point of the
sandbox. Track 9's configurable env is the fallback for people who want the
clone inside.

# Verified against the binary on this machine

`llama-server --version` on the keg this section was written against →
**build 10150 (commit dee2a846b)**, Apple clang, Darwin arm64. Every flag named in section 1.2 exists in this build,
including `--context-shift` (still valid, default on — keep it),
`--cache-reuse`, `--cache-prompt`, `-cram/--cache-ram`, `-sps`,
`--slot-save-path`, `--kv-unified-per-slot`, `-kvu`, `--jinja`,
`--chat-template`, `--chat-template-file`, `--chat-template-kwargs`,
`--reasoning-format`, `-rea`, `--reasoning-effort`, `--reasoning-budget`,
`--reasoning-budget-message`, `--reasoning-preserve`, `--samplers`,
`--sampler-seq`, `-ncmoe`, `-cmoe`, `-fit`, `-fitt`, `-fitc`,
`--mmproj-auto`, `-np`, `-cb`, and the whole `--spec-draft-*` family.

**Corrected 2026-09-29: two llama.cpp kegs are installed, and the one on `PATH`
is not the one above.** `brew` holds both `Cellar/llama.cpp/0.4.1` and
`Cellar/llama.cpp/10150`; `/opt/homebrew/opt/llama.cpp` points at `0.4.1`, so
`/opt/homebrew/bin/llama-server` is **build 10964 (commit b29c606e2)**. An
earlier revision of this section called `10964` "a misreading" of `10150`. That
was wrong, and the reasoning was circular: `10964` was a real second keg
reporting its own build, and the libraries only "said 10150" because they were
read out of the 10150 keg. Both are installed; which one a machine runs depends
on where the symlink points.

The 1.2 flag set survives this, checked against both binaries rather than
assumed. All twenty of the flags named above — `--context-shift` through
`--spec-draft-model` — appear in both `--help` outputs. So the disagreement is
about provenance rather than capability, and it is recorded because a plan that
names a build is making a claim a reader may act on. The README's pillar-1
section already carries the same finding from the app's side; this corrects the
plan to agree with it.

Also verified live, not from a document: `/props` on a running server reports
`chat_template_caps` with eight booleans, `total_slots`, and
`default_generation_settings.n_ctx`; `/v1/models` reports the model's full path
as its id; and the probe in 1.1 gets a real `tool_calls` array back from a
15.2 GB Qwen3.5 MoE.

**`/v1/messages` is served, and that was verified against a running server**
rather than read out of the binary (2026-09-27). A Claude Code shaped body —
system blocks carrying `cache_control`, a `metadata` field, and a top-level
`anthropic_beta` the router has never heard of — answers `200` with
`{"type":"message","content":[{"type":"thinking",…},{"type":"text","text":"banana"}]}`,
and the streamed form produces `message_start` … `message_stop` under the event
names an Anthropic client expects. A compiled-in route is not a working one, so
this is the check that matters.

Two things the live run settled that no amount of `strings` could. The reply's
`model` is the model's **full path**, so a client reading that field gets the
backend's name rather than the alias it asked for — the asymmetry 2.1 records.
And the `signature` on a thinking block comes back as an empty string from this
build, which is llama-server's own behaviour and not something the router
influences; a client that needs a real signature is relying on the upstream to
produce one.

**Three more, added by 2.2 and checked the same way (2026-09-28).**

The **buffered** Anthropic wire puts `signature` on the thinking block itself —
`{"type":"thinking","thinking":"…","signature":""}` — and the reply's `usage`
carries `cache_read_input_tokens` as well as `input_tokens` and
`output_tokens`.

The **streamed** Anthropic wire sends `signature_delta` as the `delta.type` of a
`content_block_delta`, and it arrives immediately after `content_block_start` —
*not* just before `content_block_stop` as this plan originally said. The block
start carries no signature at all:

```
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":""}}
```

The **OpenAI** wire carries `reasoning_content` on the delta and **no signature
field anywhere** — not on the message, not on the delta. That is what makes
2.2's priority 1 as written ("↔ Responses `reasoning` + `encrypted_content`")
unachievable on this wire, and why the router reports a signature as dropped
rather than inventing one.

One measurement to be careful with: `grep -c 'signature'` counts *lines*, and the
whole streamed event above is one line per frame, so an early count of "1
occurrence" hid the `signature_delta` frame behind the block start's. Read the
frames, not the count.

One thing the binary **rejected**, recorded so it is not rediscovered: the
ternary `PQ2_0` quantisation in `Ternary-Bonsai-2-27B-Abliterated` fails with
`tensor 'output.weight' has invalid ggml type 142. should be in [0, 43)`. This
build does not know that quant type, in the sandbox or on the host — they are
the same version.

**Two agents' config layers, read out of their binaries (2026-09-29).** The
translation table in 3.4 rests on these rather than on documentation, with one
marked exception. Claude Code 2.1.284 expands `${VAR}` in config values — it
names the behaviour in its own error strings, and its plugin validator tells
authors to write a header value as a reference rather than commit the value. The
rule that refuses a literal credential is that validator's own, ported with its
constants intact. opencode substitutes `{env:VAR}`, and its embedded
documentation says outright that "the shell-style `${VAR}` is not substituted";
its substitution function resolves a missing variable to the empty string rather
than failing. Gemini CLI is **not installed on this machine**, so its `env`-block
expansion is from the vendor's MCP documentation and is the table's only
unverified row. Codex is not installed either — `~/.local/bin/codex` is the
unrelated npm package `codex@0.2.3`, so `AgentRegistry` currently detects an
impostor — and the TOML omission rests on the format, which needs no binary.

**`/v1/messages/count_tokens` answers for real, on two builds (2026-09-29).**
The route string is present in the pinned keg's `libllama-server-impl.dylib`
(build 10150, `dee2a846b`), and a live server on build 10964 (`b29c606e2`)
answered it with `{"input_tokens":18}` for a one-line message — the same shape
Anthropic returns, which is why the router forwards the reply rather than
re-encoding it. Four probes settled the edges: a full Claude Code body carrying
`thinking`, `tool_use` and `tool_result` is accepted (68 tokens); a wrong `model`
name is not validated (200, 12 tokens); an empty `messages` array answers 6
rather than 0, so the template floor is real and `max(total, 1)` is not the same
answer; and an unknown path under `/v1/messages/` answers **404** with an
Anthropic-shaped error body — which is what lets "this backend cannot count" be
*observed* rather than guessed at. See 2.3.

# Open questions

- **`--fit` vs jxcode's own arithmetic.** Both can run; the question is whether
  `--fit` is the authority or the cross-check. Recommendation: keep jxcode's
  arithmetic as the plan, let `--fit on` catch what the plan got wrong, and
  show the disagreement — the same "prediction vs `/props`" contrast that
  already works. Needs a decision before 1.2 lands.
- **Speculative decoding needs a draft model.** `--spec-draft-*` is real but
  useless without a matching draft GGUF on disk. Either ship a pairing rule
  (like the mmproj matcher) or leave it out of the default plan.
- **Gemini activation is gated by a consent prompt** on first activation.
  Confirm whether a symlinked skill still prompts, or whether that makes
  Gemini's bind feel broken on first use.
