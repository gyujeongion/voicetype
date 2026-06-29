# Security Policy

## Supported versions

Only the latest release receives security patches.

## Reporting a vulnerability

**Do not file a public issue.** If you find a security vulnerability:

1. Submit privately via [GitHub Security Advisories](https://github.com/gyujeongion/voicetype/security/advisories/new)
2. Or open the Issues tab and use the Security label

Please include:
- Description of the vulnerability
- Steps to reproduce
- Scope of impact
- A suggested fix if you have one

## Security design

- **API keys**: stored in macOS Keychain only. Never written to disk, UserDefaults, or source code.
- **Audio**: sent directly to the STT provider you configure (Soniox, Deepgram, etc.). No intermediate server.
- **LLM text**: sent directly to the LLM endpoint you configure. The app does not log or store transcript content server-side.
- **History**: stored locally at `~/Library/Application Support/VoiceType/history.json`. Never transmitted.
- **Permissions**: microphone (active during recording only), Accessibility (optional, for auto-paste only).
- **Network**: only outbound connections to your configured STT and LLM APIs. No telemetry.
