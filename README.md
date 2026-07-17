# jxcode

Cross-platform Claude Code client — **macOS** (SwiftUI) + **Android** (Flutter).

## Architecture

```
User → Chat UI → ChatBloc → ClaudeService
                               ├── macOS: spawn jxclaude (process mode)
                               └── Android: HTTP → jxproxy:5255 (API mode)
```

| Component | Platform | Language | Role |
|-----------|----------|----------|------|
| Desktop app | macOS | Swift / SwiftUI | Full-featured Claude Code terminal client |
| Mobile app | Android | Dart / Flutter | Lightweight chat UI + proxy client |
| jxproxy | Both | TypeScript / Bun | API proxy/router — routes Messages API calls to any LLM provider |
| jxclaude | macOS | n/a (CLI) | Claude Code CLI binary, spawned as subprocess |

### Dual-mode ClaudeService

The Flutter app auto-detects its platform at runtime:

- **Process mode** (macOS) — spawns `jxclaude` as a subprocess, communicates via NDJSON over stdin/stdout. The CLI handles model routing internally.
- **API mode** (Android) — sends HTTP POST requests to `http://127.0.0.1:5255/v1/messages` through a local `jxproxy` server. Responses arrive as Server-Sent Events, parsed into `StreamEvent` objects consumed by `ChatBloc`.

On Android, the `jxproxy` server runs inside **Termux** (F-Droid). See [Android ARM64 Setup](docs/android-arm64.md) for the full guide.

## Project Structure

```
jxcode/
├── lib/                          # Flutter (Dart) app
│   ├── blocs/                    # BLoC state management
│   │   ├── chat/                 #   ChatBloc — message streaming, send/cancel
│   │   ├── proxy/                #   ProxyBloc — jxproxy configuration
│   │   ├── settings/             #   SettingsBloc — theme, model defaults
│   │   ├── project/              #   ProjectBloc — project management
│   │   ├── session/              #   SessionBloc — chat session tracking
│   │   └── permission/           #   PermissionBloc — tool approval modals
│   ├── models/                   # Data models (StreamEvent, ChatMessage, ProxyConfig...)
│   ├── services/                 # Core services
│   │   ├── claude_service.dart   #   Dual-mode ClaudeService (process + API/SSE)
│   │   ├── session_repository.dart
│   │   └── ...
│   ├── pages/                    # UI pages
│   │   ├── chat/                 #   Chat view, message list/bubble/input
│   │   ├── settings/             #   Settings with proxy configuration
│   │   ├── projects/             #   Project list + detail
│   │   └── auth/                 #   Onboarding + login
│   ├── routing/                  # go_router navigation
│   ├── theme/                    # Light/dark theme definitions
│   └── widgets/                  # Shared widgets (sidebar, status indicators)
├── JXCODE/                       # macOS (Swift / SwiftUI) app
│   ├── Services/                 # ClaudeService, ProxyManager, PermissionServer...
│   ├── Models/                   # ProxyConfig, StreamEvent...
│   └── Views/                    # SwiftUI views
├── docs/
│   └── android-arm64.md          # Full Android ARM64 setup guide
└── test/
    └── claude_service_api_test.dart  # SSE parser tests
```

## Build

### Flutter (Android + macOS)

```bash
# Dependencies
flutter pub get

# Analyze
flutter analyze

# Test
flutter test

# Build Android APK (ARM64)
flutter build apk --split-per-abi

# Build macOS (via Xcode)
open JXCODE.xcodeproj  # then Cmd+R
```

### Swift (macOS native)

Open `JXCODE.xcodeproj` in Xcode and build with Cmd+R.

## Setup

### macOS

```bash
# Install jxclaude (the Claude CLI binary)
npm install -g @anthropic-ai/claude-code
# Or place your jxclaude binary at ~/.local/bin/jx-claude

# (Optional) Install jxproxy for provider routing
curl -fsSL https://raw.githubusercontent.com/marshaljlee/jxproxy/main/install.sh | bash
```

### Android

See [docs/android-arm64.md](docs/android-arm64.md) for the full Termux + jxproxy setup.

Quick summary:

1. Install Termux from F-Droid
2. `pkg install bun proot -y`
3. `curl -fsSL https://raw.githubusercontent.com/marshaljlee/jxproxy/main/install.sh | bash`
4. `proot -b /data/data/com.termux/files/usr/tmp:/tmp`
5. `jxproxy server --port 5255`
6. Open jxcode app — auto-connects to `127.0.0.1:5255`

## Tech Stack

| Layer | macOS | Android |
|-------|-------|---------|
| Language | Swift 6 | Dart 3.12+ |
| UI | SwiftUI | Flutter 3.44+ |
| State | @Observable AppState | BLoC (flutter_bloc) |
| Routing | SwiftUI Navigation | go_router |
| Proxy | ProxyManager (spawns jxproxy) | ProxyBloc → ClaudeService API mode |
| Terminal | SwiftTerm | N/A (uses jxproxy) |
| Min target | macOS 15.0 | Android 8.0+ (API 26) |
