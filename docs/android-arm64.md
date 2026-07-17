# Android ARM64 Setup

Run jxcode on Android ARM64 devices — the Flutter app connects to a local `jxproxy` server running inside Termux, which proxies Claude API calls to your provider of choice.

## Architecture

```
┌─────────────────────────────────────┐
│         Android Device             │
│  ┌─────────────────────────────┐   │
│  │   jxcode (Flutter app)      │   │
│  │   · API mode                │   │
│  │   · HTTP to 127.0.0.1:5255 │   │
│  └──────────┬──────────────────┘   │
│             │ HTTP/SSE             │
│  ┌──────────▼──────────────────┐   │
│  │   Termux                    │   │
│  │   · jxproxy (Bun)          │   │
│  │   · port 5255              │   │
│  │   · routes to Anthropic /   │   │
│  │     OpenRouter / local LLM │   │
│  └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

On Android, the Flutter app cannot spawn the `jxclaude` CLI binary directly (no ARM64 binary, no subprocess spawning from mobile apps). Instead, **API mode** sends HTTP requests to `http://127.0.0.1:5255/v1/messages` — the standard Anthropic Messages API — which the local `jxproxy` server handles.

## Prerequisites

- Android device with **ARM64** (arm64-v8a) CPU
- [Termux](https://f-droid.org/packages/com.termux/) from **F-Droid** (the Google Play version is abandoned and won't work)
- ~1 GB free storage
- An API key for at least one LLM provider (Anthropic, OpenRouter, OpenCode, etc.)

## Step-by-Step Setup

### 1. Install Termux

Download and install Termux from [F-Droid](https://f-droid.org/packages/com.termux/).

### 2. Install Dependencies

Open Termux and run:

```bash
pkg update && pkg upgrade -y
pkg install bun proot -y
```

- **bun** — JavaScript runtime used by jxproxy
- **proot** — needed to fix Android's `/tmp` restriction (see step 4)

### 3. Install jxproxy

```bash
curl -fsSL https://raw.githubusercontent.com/marshaljlee/jxproxy/main/install.sh | bash
```

This installs the `jxproxy` server binary, creates `~/.jxproxy/config.env`, and adds `~/.local/bin` to your PATH.

### 4. Fix `/tmp` Access

Android blocks direct access to `/tmp`, which some tools require. Create a proot alias:

```bash
echo 'alias jxproxy="proot -b /data/data/com.termux/files/usr/tmp:/tmp jxproxy"' >> ~/.bashrc
source ~/.bashrc
```

Or run it inline each time:

```bash
proot -b /data/data/com.termux/files/usr/tmp:/tmp jxproxy server --port 5255
```

### 5. Configure jxproxy

Edit `~/.jxproxy/config.env`:

```bash
# Required: set your provider API key
ANTHROPIC_API_KEY=sk-ant-...    # or OPENROUTER_API_KEY, OPENCODE_API_KEY, etc.

# Port (must match jxcode's default)
JXPROXY_PORT=5255

# Provider (direct=Anthropic, openrouter, opencode-zen, openai, local)
JXPROXY_PROVIDER=direct

# Model
MODEL=claude-sonnet-5-20251001
```

### 6. Start jxproxy

```bash
jxproxy server --port 5255
```

Keep Termux running in the background. Use `termux-wake-lock` to prevent Android from killing it:

```bash
termux-wake-lock
```

### 7. Launch jxcode

Open the jxcode Flutter app on your Android device. The app automatically detects Android and connects to `127.0.0.1:5255` in API mode. No additional configuration needed.

## How API Mode Works

The Flutter app (`ClaudeService`) detects `Platform.isAndroid` and switches to API mode:

| Aspect | Process mode (macOS) | API mode (Android) |
|--------|---------------------|--------------------|
| Transport | stdin/stdout NDJSON | HTTP POST + SSE |
| Endpoint | jxclaude binary | `127.0.0.1:5255/v1/messages` |
| Stream format | NDJSON lines | Server-Sent Events |
| Auth | ANTHROPIC_API_KEY env | jxproxy handles keys |
| Model routing | Claude CLI decides | jxproxy routes to provider |

## Troubleshooting

### "Cannot connect to proxy"

Verify jxproxy is running in Termux and listening on port 5255:

```bash
curl -s http://127.0.0.1:5255/health
```

### App crashes on startup

The Flutter app requires network access. Ensure:
- Termux is running (not killed by battery optimization)
- `termux-wake-lock` is active
- No VPN or firewall is blocking `127.0.0.1:5255`

### Proot fails

If the proot alias doesn't work, try the full command:

```bash
proot -b /data/data/com.termux/files/usr/tmp:/tmp /data/data/com.termux/files/home/.local/bin/jxproxy server --port 5255
```

## Building jxcode for Android

```bash
flutter build apk --split-per-abi
```

Output: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

## API Mode Tests

Run the SSE parsing tests:

```bash
flutter test test/claude_service_api_test.dart
```
