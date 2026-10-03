# JXCode for Android (arm64-v8a)

The same three pillars as the macOS app — an isolated terminal, registered
backends routed through one local server, and on-device GGUF — rebuilt for
Android.

It is a **Kotlin port, not a cross-compile.** The macOS app is SwiftUI +
AppKit + SwiftTerm, and three of its load-bearing modules are Apple-only:

| macOS module | Why it cannot be compiled for Android | Android replacement |
|---|---|---|
| `JXCodeApp` (10 files) | SwiftUI + AppKit + SwiftTerm | Jetpack Compose, custom terminal renderer |
| `ModelRouter.swift` | `Network.framework` (`NWListener`) | `java.net.ServerSocket` on loopback |
| `PTYSession.swift` | `import Darwin` (`forkpty`, `WIFEXITED`) | JNI `forkpty` from bionic's `<pty.h>` |
| `RouterAuth.swift` | Security framework (Keychain) | AndroidKeyStore AES-GCM |
| `LlamaServerSupervisor` | spawns `llama-server` | in-process JNI (Android blocks exec from app data) |

`JXCodeCore` was 37 files of almost pure Foundation, so its logic — the
Anthropic ⇄ OpenAI translation, SSE framing, HTTP parsing, provider store,
token estimator — moved across essentially unchanged. Known bugs and their
fixes came with it (see "Bugs inherited deliberately" below).

## Build

```bash
./build.sh debug      # app/build/outputs/apk/debug/app-debug.apk
./build.sh install    # builds and installs on the attached device
./build.sh release    # app/build/outputs/apk/release/app-release-unsigned.apk
./build.sh native     # rebuild the native libs (see below)
```

`release` is minified and resource-shrunk — 44 MB against 106 MB for debug —
and takes about 20 minutes, nearly all of it in R8. It comes out **unsigned**,
because there is no `signingConfig` in `app/build.gradle.kts`, so it has to be
signed before it will install:

```bash
BT=$ANDROID_HOME/build-tools/36.1.0
"$BT/zipalign" -p -f 4 app-release-unsigned.apk app-release.apk
"$BT/apksigner" sign --ks ~/.android/debug.keystore \
    --ks-key-alias androiddebugkey \
    --ks-pass pass:android --key-pass pass:android app-release.apk
```

Both build-tools wrappers are Java programs and do **not** inherit `JAVA_HOME`
from the shell that calls them, so export it first or they fail with "Unable to
locate a Java Runtime" — the same trap `build.sh` exists to avoid.

Requirements: JDK 21 (picked up from Android Studio's JBR or Homebrew),
Android SDK with platform 36 and NDK 28, and — behind a proxy — the
`HTTP_PROXY`/`HTTPS_PROXY` environment variables, which `build.sh` translates
into the `-D` system properties Java actually reads. Java ignores those
variables on its own, which presents as Gradle hanging during dependency
resolution.

### Native libraries

```bash
native/fetch-llama.sh        # shallow clone of llama.cpp (pinned by commit)
native/build-native.sh       # libjxpty.so + llama.cpp + libjxllama.so
native/build-native.sh pty-only
native/build-runtime.sh      # node + curl + npm + CA bundle into the APK
native/build-runtime.sh clean  # re-resolve, re-download, stage from scratch
```

The runtime is built from `native/runtime-packages.txt` (one Termux package
per line; dependencies are resolved transitively). `fetch-termux.py` writes
the resolved list to `runtime/deb-manifest.txt`, and `build-runtime.sh` stages
only those files — so a stray .deb in the cache cannot change the APK.

Both are built with the NDK clang directly and dropped into
`app/src/main/jniLibs/arm64-v8a`, rather than through AGP's
externalNativeBuild: the SDK has no bundled cmake, and keeping a 10-minute
C++ tree out of Gradle means it never rebuilds because a Kotlin file changed.
The app degrades gracefully if `libjxllama.so` is absent — the Runtime tab
says so instead of the router crashing.

## Design

The chrome is the macOS app's design, ported: `ui/theme/Theme.kt` mirrors
`Theme.swift` / `Palette.swift` (page `#141319`, card `#191919`, elevated
`#242427`, amber `#FEB43B`, the seven identity tiles with their derived inks)
and `Type` pins every Material role to the small sizes the SwiftUI app uses —
a default `bodyLarge` of 16sp is what made these screens read as a different
app. `ui/Components.kt` holds the shared parts: `AppCard`, `SectionLabel`,
`Badge`, `IconTile`, `PrimaryButton`.

Unlike the macOS app, this one is **dark-only, deliberately** — see the comment
in `res/values/themes.xml`. The window background has to match the terminal or
the IME and status-bar seams show, and there is no light terminal here for a
light page to match. The desktop follows the system appearance because it has
no such seam to hide. Do not "fix" this by adding a light palette.

## What is here

- **Terminal** — VT100/ANSI buffer with cursor addressing, scroll regions,
  erase-in-line and 256-colour SGR, rendered run-length on a Compose canvas.
  Agent TUIs redraw by moving the cursor, so an append-only renderer shows
  them as garbage; that is why the parser is real.
- **Router** — loopback `ServerSocket` on port 5255 exposing `/v1/messages`,
  `/v1/chat/completions`, `/v1/models`, `/v1/messages/count_tokens`, `/health`.
  Every agent CLI inherits `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` from the
  sandbox environment, so pointing an agent at a backend needs no per-agent
  setup.
- **Sandbox** — `filesDir/env/home` as a private `$HOME`, with
  `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `GEMINI_CONFIG_DIR` pinned explicitly
  because `getpwuid()` still returns the real home when `$HOME` is overridden.
- **Local GGUF** — llama.cpp in-process through JNI, using the model's own
  embedded chat template (`llama_chat_apply_template`), exposed as a normal
  provider behind the router.
- **Bundled runtime** — Node, npm, npx and curl ship inside the APK, so an
  agent CLI can be `npm i -g`-ed on a phone with nothing else installed. See
  below.

### Bundled runtime

Node comes from Termux's aarch64 packages, which means it arrives with the
dependencies a distro build has and an APK does not want:

| Problem | Why it matters | Fix |
|---|---|---|
| W^X (Android 10+) | nothing in `filesDir` can be exec'd | binaries stay as jniLibs and are launched from `nativeLibraryDir` |
| AGP packages `*.so` only | `libcrypto.so.3`, `libicuuc.so.78` are silently dropped from the APK | whole closure renamed to `libjx*.so`, ELF rewritten with patchelf |
| Termux `RUNPATH` | points at `/data/data/com.termux/...`, which is absent | `LD_LIBRARY_PATH=nativeLibraryDir` set for every spawned process |
| npm is ~2000 files | asset-per-file would dominate build time | shipped as `assets/runtime/npm.zip`, expanded on first boot |

Executables take a `libjxbin_` prefix (`libjxbin_node.so`) so that `bin/curl`
and `libcurl.so` cannot collapse onto one name. Only JavaScript and data are
unpacked into the sandbox; `$HOME/.local/bin/{node,npm,npx,curl}` are
three-line `#!/system/bin/sh` wrappers that exec the real binary by absolute
path, because no shell would ever look for `libjxbin_node.so`.

Git is deliberately *not* bundled: git is `bin/git` plus ~150 `git-core`
helpers that must keep their original names, and only `*.so` survives
packaging. It is the one common tool the W^X + AGP combination rules out.

## Bugs inherited deliberately

These were found the hard way on macOS and are guarded against here:

1. **HTTP heads are parsed at the byte level, on `0x0A`, with `0x0D`
   stripped.** Splitting on a newline *character* silently drops every header
   when the stream is CRLF — `Content-Length` included — which surfaces as a
   500 with an empty body.
2. **`OpenAIMessage.role` defaults to `"assistant"`.** Streaming deltas carry
   `role` only on the first chunk; requiring it makes every later chunk throw
   and truncates the stream to one token.
3. **Streaming terminates on upstream EOF, not on `finish_reason`.** With
   `stream_options.include_usage` the real token counts arrive in a later
   chunk with empty `choices`.
4. **`stop_reason` is derived from content, not from `finish_reason`.**
   Backends report `stop` even on tool calls, and the agent loop only
   continues when it sees `tool_use`.
5. **`ProviderStore.add` dedupes on `(baseURL, kind)`, not just `id`.**
   Registering the same backend twice otherwise appends duplicates that all
   point at one port.
6. **Provider API keys live in the keystore, never in `providers.json`;** only
   the alias is written to disk, so a provider list can be exported or logged
   safely.

## Known limits

- **No bundled git.** Node, npm, npx and curl are in the APK, but git's
  `git-core` helpers cannot be packaged (see above); agents that shell out to
  git will report it as missing.
- **CPU-only inference** (`n_gpu_layers = 0`). Vulkan/OpenCL backends are
  device-dependent; 2–4 GB Q4 models are the realistic ceiling on a phone.
- **Router has no auth and binds loopback.** Same trust boundary as local
  Ollama or LM Studio — narrower here, since no other uid can reach the port.
- **arm64 only.** 32-bit has no address space for an in-process GGUF runtime.
