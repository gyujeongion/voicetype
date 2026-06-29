# Contributing to VoiceType

## Bug reports

When filing an issue, include:
- macOS version (e.g. macOS 15.4)
- STT engine and LLM provider (e.g. Soniox + DeepSeek)
- App version (menu bar → "Check for Updates…")
- **Diagnostics** — error alert → "Copy Diagnostics" → paste into the issue
- Steps to reproduce

## Feature requests

Open an issue with the `enhancement` label.

## Pull requests

1. Fork the repo and create a branch: `feature/your-feature` or `fix/your-bug`
2. Make your changes
3. Run `swift test` — all tests must pass
4. If you touch VoiceTypeCore, add or update tests for your change
5. Open a PR with a short description of what changed and why

## Adding a new STT engine

Implement the `STTEngine` protocol and register it in `STTEngineFactory`. See the "Adding a new STT engine" section in README for the protocol definition.

## Dev setup

- macOS 14+, Swift 6.0+ (Xcode 16+)
- Dependencies are managed by SPM — nothing to install manually

```bash
git clone https://github.com/gyujeongion/voicetype.git
cd voicetype
swift build
swift test
```

## Code style

- Swift 6 concurrency (`Sendable`, `@MainActor`)
- Comments only for non-obvious *why*, not *what*
- VoiceTypeCore must stay free of AppKit/AVFoundation imports
