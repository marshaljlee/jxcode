# Handoff — 2026-07-09

## Goal
Fix 6 issues in JXCODE: proxy routing auth, brainwave theme, proxy dot, font system, version display, settings organization.

## Current State
All changes applied and build succeeds. The critical auth fix (ANTHROPIC_API_KEY) means the stock claude binary now sends the correct `x-api-key: jxproxy` header through the jxproxy.

## Active Files
- `JXCODE/Services/ClaudeService.swift` — ANTHROPIC_API_KEY added
- `JXCODE/Views/MainView.swift` — ProxyIndicatorDot (no label, live detection), version display
- `Packages/Sources/JXCODECore/Theme/AppTheme.swift` — brainwave colors, ThemeStore font system
- `Packages/Sources/JXCODECore/Theme/ClaudeTheme.swift` — size() functions use absolute font
- `JXCODE/App/AppState.swift` — absolute font size properties
- `JXCODE/Views/SettingsView.swift` — cleaned up categories
- `JXCODE/Views/Settings/PaseoAppearanceTab.swift` — notifications/panel layout, font sliders
- `JXCODE/Views/Settings/AdvancedSettingsTab.swift` — jxproxy binary hint

## Changes Made
1. **Proxy routing** — Added `ANTHROPIC_API_KEY=jxproxy` to subprocess environment. Stock claude now sends correct auth to jxproxy.
2. **Brainwave theme** — Changed from magenta-pink ("blackpink") to electric cyan (`#00D4FF`) on deep navy. Light counterpart changed to icy blue-white.
3. **Proxy dot** — Removed "PRX ON/OFF" label. Now uses `effectiveProxyActive` (live `/health` polling via `isPortActive`). Pure dot with glow shadow.
4. **Font system** — Changed from relative offset model to absolute font size (default 12pt). `ClaudeTheme.size()` now scales relative to the user's absolute pref. Settings UI shows "12pt" directly.
5. **Version display** — Changed from `"JXCODE(1.3.9) — CC 2.1.201"` string to a custom toolbar with JXCODE in semibold, version in small tertiary, CC version in faded (`opacity(0.6)`) 9pt.
6. **Settings categories** — Reduced from 6 to 4 functional categories: General (Appearance/Chat/Permissions), Network (Proxy/Environment), Developer (Advanced/Commands/Shortcuts/Hooks/CLAUDE.MD/Storage), Account (Usage/Diagnostics). Removed orphan "Projects" tab.

## Failed Attempts
None.

## Next Steps
1. Run the compiled JXCODE app to verify the proxy now routes correctly
2. Check if the brainwave theme colors match Master's visual reference
3. The jxproxy binary embedded in the app bundle (`jxproxyBinary`) could be bundled into the .app for one-click deployment
