# JXCODE Design Research Report

## Executive Summary

Comprehensive analysis of JXCODE's visual appeal, navigation, user experience, branding, and AI-driven personalization. Based on deep research of the current SwiftUI codebase and comparison with industry standards for AI coding tool interfaces.

---

## 1. Current Design Assessment

### Color System — Status: Good Foundation

**What exists:**
- 8 theme variants (Terracotta, Ocean, Forest, Lavender, Midnight, Amber, Brainwave Dark, Brainwave Light)
- Comprehensive `ThemeColors` struct with 28 semantic color properties
- `ClaudeTheme` enum providing computed theme access
- Adaptive light/dark color pairs via `Color(light:dark:)`
- No true black or true white in any theme (requirement met)

**Recommendations:**
- Add a `primaryAccent` override in settings to let users tint themes
- Expose theme `contrastLevel` to handle accessibility (WCAG AAA)
- For code syntax highlighting, define a `SyntaxColors` type keyed by token category (keyword, string, comment, etc.) so themes can customize their code view

### Typography — Status: Good

**What exists:**
- JetBrains Mono NL globally overridden via Font.system() extensions
- Size helpers in `ClaudeTheme.size()` and `ClaudeTheme.messageSize()`

**Recommendations:**
- Add `Font.TextStyle` scaling (title, headline, body, caption) using semantic type hierarchy rather than fixed 11pt everywhere
- Define a `secondaryFont` for UI labels that remains system UI (Inter/SF Pro) to distinguish code from interface text
- The current `Font.system()` override forces everything to JetBrains Mono 11pt — consider making UI elements use `.system(.body)` while code blocks use `.custom("JetBrains Mono NL")`

### Spacing & Layout — Status: Needs Improvement

**What exists:**
- Corner radius constants: `cornerRadiusSmall: 8`, `cornerRadiusMedium: 12`, `cornerRadiusLarge: 16`, `cornerRadiusPill: 20`

**Recommendations:**
- Define a full spacing scale: 4, 8, 12, 16, 20, 24, 32, 48
- Use `.padding()` consistently with these named constants instead of magic numbers
- Add `ClaudeTheme.contentWidth` for maximum readable line width (~720px for chat)
- Standardize sidebar width (current min:240 / ideal:290 / max:380 seems good)

### Component Styling — Status: Good

**What exists:**
- `ClaudeAccentButtonStyle`, `ClaudeSecondaryButtonStyle` 
- `ClaudeSendButton` (circular)
- `ClaudeThemeDivider`
- `.claudeCard()` and `.claudeInputField()` view modifiers

**Recommendations:**
- Add loading/skeleton states for chat streaming (current implementation uses solid blocks)
- Add `hapticFeedback` on key interactions (send, tool execution, permission approve/deny)
- Define a `ToolBarItemStyle` for the segmented control items
- Improve the segmented control with visual feedback for drag/selection animation (currently `spring(response:0.25,dampingFraction:0.8)`)

---

## 2. Navigation Architecture

### Current Structure
- `NavigationSplitView` with sidebar (Sessions/Files/Agents/MCP tabs) 
- Dedicated project windows via `WindowGroup(id: "project-window")`
- Settings via system `Settings` scene
- Inspector panel (terminal + memo) dockable right/bottom
- Push notifications via `NotificationService`

### Recommendations
- Add keyboard navigation shortcuts for all sidebar tabs (current only Cmd+1 for history, Cmd+2 for files)
- Implement tab reordering by drag
- Consider adding a "Quick Open" (Cmd+P) palette for switching projects/sessions
- The inspector split (memo + terminal) could benefit from a unified search

---

## 3. AI Interaction Feedback

### What exists
- Streaming text delta buffered at 50ms intervals
- Thinking state indicator
- Context usage percentage display
- Model/effort/permission mode selectors per session
- Permission approval modals (Safe/Moderate/High risk tiers)

### Recommendations
- Add a visual token counter showing input/output token usage in real-time during streaming
- Show estimated cost per turn as a small live annotation
- Add "stop reason" explanations (why the model stopped — token limit, tool use, etc.)
- Improve the AskUserQuestion interaction with inline options rather than the current hook-based approval

---

## 4. Branding Identity

### Current brand elements
- Bundle ID: `com.idealapp.JXCODE`
- Terracotta accent (#D97757) as default theme
- Topbar: `JXCODE(version) — CC [cli-version]`
- Name derived from "JXCODE" — positioning as a Claude Code desktop client

### Recommendations
- Design a proper app icon (current uses default SwiftUI sparkle)
- Add a subtle branded splash/welcome sequence on first launch
- The GitHub URL in settings points to `github.com/ttnear/JXCODE` — verify this is correct
- Add "About JXCODE" window with version, credits, and tech stack

---

## 5. AI-Driven Personalization Opportunities

1. **Smart theme switching**: Auto-switch between brainwaveLight/brainwaveDark based on time of day or ambient light sensor
2. **Usage-based model suggestions**: Track which models deliver best results per task type and suggest them
3. **Session clustering**: Group related sessions into "workspaces" with shared context
4. **Adaptive permission mode**: Auto-lower permission restrictions for trusted, repetitive tool patterns
5. **Context-aware font sizing**: Adjust message font size based on message length and screen real estate

---

## 6. Accessibility & Inclusivity

### Current state
- SwiftUI default accessibility labels
- Dynamic type support limited (font adjustment in settings)
- Color contrast depends on theme

### Recommendations
- Add explicit `.accessibilityLabel()` and `.accessibilityHint()` to all interactive elements
- Implement `@AccessibilityFocusState` for permission modals
- Ensure all themes pass WCAG AA contrast ratio (4.5:1 for normal text)
- Test with VoiceOver for all major workflows (chat, permissions, settings)

---

## 7. Performance Observations

- `AppState` is a single `@Observable` class — splitting into focused feature stores would reduce SwiftUI body re-evaluation
- Text delta buffering at 50ms is well-calibrated for smooth streaming
- Permission server using localhost HTTP (ports 19836-19846) is a clean approach
- Move heavy operations (session reload, file watching) off `@MainActor` where possible (already done for some)

---

## References

- ClaudeTheme.swift: `/Packages/Sources/JXCODECore/Theme/ClaudeTheme.swift`
- AppTheme.swift: `/Packages/Sources/JXCODECore/Theme/AppTheme.swift`
- MainView.swift: `/JXCODE/Views/MainView.swift`
- SettingsView.swift: `/JXCODE/Views/SettingsView.swift`
- AppState.swift: `/JXCODE/App/AppState.swift`
