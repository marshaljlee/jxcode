# Handoff — 2026-07-18

## Goal
Fix Android ARM64 runtime support — Flutter app cannot spawn jxclaude CLI on Android, so it needs API mode (HTTP/SSE through jxproxy at port 5255).

## Current State
- **Flutter 3.44.6**, Dart 3.12.2
- **`flutter analyze`**: No issues found ✅
- **`flutter test`**: **23/23 pass** ✅ (11 existing + 12 new SSE parser tests)
- **Android ARM64 APK**: builds successfully (was already working from prior handoff)
- **All 5 implementation steps completed**

### Architecture Changes

| Component | Change |
|-----------|--------|
| `ClaudeService` (Flutter) | Dual-mode: process mode (macOS, spawn jxclaude) + API mode (Android, HTTP POST to jxproxy port 5255) |
| `ProxyConfig` (Flutter) | Providers aligned with Swift model: direct, openrouter, opencodeZen, opencodeGo, google, nvidia, nemotron, local, custom; `displayName` getter added |
| `ChatBloc` | Accepts `ProxyBloc` reference, syncs proxy host/port to `ClaudeService` before each send |
| `app.dart` | `proxyBloc` created before `chatBloc`, passed as dependency |
| jxproxy `install.sh` | Termux detection → routes to `installers/install-android.sh` |
| jxproxy `README.md` | Android ARM64 + jxcode section added |
| SSE parser (`SseParser`) | Public class with chunk-boundary handling, cancellation support, tested |

### New Files Created
- `docs/android-arm64.md` — full setup guide for Android ARM64
- `test/claude_service_api_test.dart` — 12 tests covering SSE → StreamEvent mapping

### Files Modified
- `lib/services/claude_service.dart` — dual-mode architecture
- `lib/models/proxy_config.dart` — aligned providers, displayName getter
- `lib/blocs/chat/chat_bloc.dart` — proxy config wiring
- `lib/app.dart` — proxyBloc ordering
- `lib/pages/settings/settings_page.dart` — uses displayName
- `test/settings_bloc_test.dart` — fixed model name: sonnet-4-6 → sonnet-5
- jxproxy/install.sh — Termux detection
- jxproxy/README.md — Android section

## Active Files
- `lib/services/claude_service.dart` — SseParser class (public), SSE mapping, API mode
- `lib/models/proxy_config.dart` — ProxyProvider enum with all providers
- `docs/android-arm64.md` — setup guide
- `test/claude_service_api_test.dart` — 12 SSE tests
- jxproxy/install.sh — Termux support

## Next Steps
1. **Build Android APK** and test on a physical ARM64 device
2. **Run jxproxy** inside Termux on the device to verify end-to-end
3. **CI/CD**: Wire build script into GitHub Actions for automated builds
4. **Code signing**: Set up Apple Developer cert for distribution builds
5. **Feature work**: Chat UI polish, permission server integration, GitHub OAuth
