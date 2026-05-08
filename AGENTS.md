# Repository Guidelines

## Project Structure & Module Organization

This repository contains a native macOS menu bar app for viewing Claude Code and Codex usage. The app lives under `native/`.

- `native/Sources/AIUsageBar/`: Swift source files for the app, UI, store, OAuth readers, API clients, and usage models.
- `native/Resources/Info.plist`: app bundle metadata, including menu-bar-only behavior.
- `native/build.sh`: production bundle script using `swiftc`, AppKit, SwiftUI, and ad-hoc signing.
- `native/Package.swift`: SwiftPM manifest for IDE support and package-level compilation.
- `docs/`: documentation assets such as `docs/screenshot.png`.

Generated bundles are written to `native/build/`; do not commit build output.

## Build, Test, and Development Commands

Run commands from the repository root unless noted.

- `cd native && ./build.sh`: canonical build; compiles with `swiftc`, copies resources, and ad-hoc signs `build/AIUsageBar.app`.
- `ditto native/build/AIUsageBar.app ~/Applications/AIUsageBar.app`: installs or updates the local app bundle for manual testing.
- `cd native && swift build`: optional SwiftPM check for IDE/toolchain environments; `./build.sh` is the required smoke test.

There is currently no automated test target. Use `./build.sh` as the minimum smoke test before submitting changes.

## Coding Style & Naming Conventions

Use Swift 5.8-compatible code targeting macOS 13 Ventura and Apple Silicon. Keep dependencies limited to system frameworks unless there is a clear reason to expand the footprint.

Follow the existing style: 4-space indentation, `PascalCase` for types, `camelCase` for properties/functions, and small focused files by responsibility. Prefer immutable `let` values, explicit models, `@MainActor` for UI-facing state, and concise comments only where behavior is not obvious.

## Testing Guidelines

For UI or OAuth changes, manually verify the menu bar menu, refresh behavior, unavailable-token states, and error fallback display. Avoid committing real credentials or local snapshots.

If adding automated tests, create an XCTest target under `native/Tests/AIUsageBarTests/` and name files after the unit under test, for example `UsageReaderTests.swift`. Document any new test command here.

## Commit & Pull Request Guidelines

Recent commits use short, lowercase prefixes such as `docs:` and `initial:`. Keep messages concise and imperative, for example `docs: update install steps` or `usage: handle missing codex auth`.

Pull requests should include a brief description, the commands run, manual verification notes, and screenshots or screen recordings for visible UI changes. Link related issues when available.

## Security & Configuration Tips

The app reads Claude credentials from the macOS keychain and Codex auth from `~/.codex/auth.json`. Never commit tokens, copied auth files, local caches, or built `.app` bundles.
