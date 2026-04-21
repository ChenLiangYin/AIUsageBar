# AIUsageBar

A Mac menu bar app that shows real **Claude Code** and **Codex** rate-limit
utilization at a glance. Pure Swift + AppKit + SwiftUI. macOS 13 Ventura or
later, Apple Silicon.

## Install

```bash
cd native
./build.sh
cp -R build/AIUsageBar.app ~/Applications/    # or /Applications/
```

First launch is an ad-hoc-signed app, so macOS will say "unidentified
developer." Right-click → Open once, then confirm.

macOS will also prompt for keychain access on the first Claude OAuth read —
click **Always Allow**.

## What it shows

| Provider | Source | Bars |
|---|---|---|
| Claude Code | `/api/oauth/usage` on `api.anthropic.com` (token from keychain `Claude Code-credentials`) | 5h session · 7 days, both as utilization % with reset countdown |
| Codex | `/wham/usage` on `chatgpt.com/backend-api` (token from `~/.codex/auth.json`) | primary + secondary rate-limit windows as used_percent |

If the OAuth call 429s or fails transiently, the UI shows the last good
snapshot with a note — no silent regression to "raw tokens."

If neither token is available, Claude falls back to a local jsonl scan
(`~/.claude/projects/**/*.jsonl`) and shows raw token totals.

## Layout

```
native/
├── Package.swift                        # present for IDE; build.sh uses swiftc
├── Resources/Info.plist                 # LSUIElement=true (no Dock)
├── build.sh                             # swiftc compile + bundle + ad-hoc sign
└── Sources/AIUsageBar/
    ├── AIUsageBarApp.swift              # @main + NSStatusItem + NSPopover
    ├── ContentView.swift                # SwiftUI popup
    ├── UsageStore.swift                 # @MainActor store, 90s refresh loop
    ├── UsageModels.swift                # ProviderUsage / UsageBar / UsageSnapshot
    ├── UsageReader.swift                # OAuth-first orchestration + snapshot cache
    ├── ClaudeOAuth.swift                # Keychain read
    ├── ClaudeOAuthClient.swift          # Claude /api/oauth/usage
    ├── CodexOAuth.swift                 # ~/.codex/auth.json read
    └── CodexOAuthClient.swift           # Codex /wham/usage
```

Runtime footprint: ~28 MB RSS, 336 KB bundle, no third-party dependencies.

## Auto-start on login (optional)

```bash
cat > ~/Library/LaunchAgents/app.aiusagebar.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>app.aiusagebar</string>
  <key>ProgramArguments</key><array>
    <string>/Users/YOU/Applications/AIUsageBar.app/Contents/MacOS/AIUsageBar</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>Crashed</key><true/><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
EOF

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/app.aiusagebar.plist
```

Uninstall: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/app.aiusagebar.plist && rm ~/Library/LaunchAgents/app.aiusagebar.plist ~/Applications/AIUsageBar.app -rf`

## Credits

The OAuth usage endpoints were discovered by reading the excellent
[CodexBar](https://github.com/steipete/CodexBar) source by Peter Steinberger.
This project is an independent reimplementation targeting macOS 13 Ventura —
no code is copied from CodexBar.

## Why built from scratch (vs. CodexBar / ClaudeBar)

Ventura's Command Line Tools ship the macOS SDK with SwiftUI / AppKit /
Combine, and `swiftc` alone links them — so "no SwiftUI on Ventura" is not
the blocker for those apps. The real blockers are version-locked:

- **Swift toolchain** — CodexBar's `Package.swift` requires
  `swift-tools-version: 6.2`. The newest Swift installable on macOS 13 is 5.8
  (via CLT 14.3); Swift 6.2 has no Ventura build. CodexBar's sources use
  `@Observable`, Swift macros, typed throws — they fail to parse under 5.8.
- **SDK symbols** — Ventura is stuck on `MacOSX13.sdk`; CodexBar links
  against `Observation`, newer `MenuBarExtra` styles, and other macOS 14 /
  15-only symbols that are undefined at link time on 13.

This project is independent of CodexBar's source tree and compiles cleanly on
a stock Ventura + CLT 14.3 install.
