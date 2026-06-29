# 배포 포스팅 초안

---

## Show HN (Hacker News)

**제목:**
```
Show HN: VoiceType – Free macOS dictation with real-time Soniox streaming (BYOK, open source)
```

**본문:**
```
I built this because Spokenly is the only macOS app that supports real-time Soniox streaming,
but they lock it to their subscription. Every other app (Superwhisper, Wispr Flow) batches
audio — you speak into a void and wait.

VoiceType streams over a persistent WebSocket. Words appear on the indicator as you talk,
so you get instant feedback mid-sentence. F8 to start, F8 again to inject text at cursor.

Technical notes:
- Soniox stt-rt-v5 via WebSocket — the finalize/`<fin>` handshake took a while to figure out
  (send {"type":"finalize"}, wait for `<fin>` token, filter it from output)
- Audio: 16kHz mono s16le PCM, 0.1s frames (3200 bytes)
- context.terms for custom vocabulary — works better than post-processing for proper nouns
- LLM post-processing optional — DeepSeek Chat (~0.9s) or any OpenAI-compatible endpoint
- Sparkle for auto-updates, EdDSA signed
- ~700KB bundle, Swift 6, macOS 14+

Also supports Deepgram Nova-3. No server, no telemetry, API keys in Keychain only.

GitHub: https://github.com/gyujeongion/voicetype
```

---

## Reddit r/macapps

**제목:**
```
VoiceType – free open source macOS dictation with real-time Soniox BYOK (words appear as you speak)
```

**본문:**
```
Built this because I wanted Spokenly-style real-time streaming dictation but without the subscription.

**What makes it different:**
Most dictation apps work like this: record → stop → wait → text. You're speaking into a void.

VoiceType streams over WebSocket — words appear on a floating indicator **as you talk**, word by word.
Soniox's real-time model (stt-rt-v5) is genuinely the best for Korean, but it works great for
English too.

**Features:**
- F8 to start/stop, text injected at cursor (Accessibility API)
- Bring your own Soniox or Deepgram API key — no subscription
- Custom vocabulary (registers terms directly with the STT model, not post-processing)
- Optional LLM post-processing — translate, clean up filler words, summarize
- History of last 300 dictations (raw STT + final output)
- Sparkle auto-updates

**Free, open source (MIT):** https://github.com/gyujeongion/voicetype

Soniox gives free credits to start. Happy to answer questions about the Soniox WebSocket
protocol — the finalize handshake is non-obvious.
```

---

## 클리앙 / 뽐뿌 (한국어)

**제목:**
```
[맥앱] 무료 실시간 받아쓰기 앱 만들었습니다 — Soniox API 키 직접 쓰는 오픈소스
```

**본문:**
```
Spokenly 쓰다가 구독 끊고 직접 만들었습니다.

**다른 앱이랑 차이:**
대부분 받아쓰기 앱은 녹음 → 종료 → 기다림 → 텍스트 순서입니다.
VoiceType은 말하는 동안 단어가 실시간으로 화면 상단에 나타납니다.
인식이 되고 있는지 바로 보이니까 말하다가 고칠 수 있어요.

**사용법:**
1. Soniox에서 API 키 발급 (무료 크레딧 제공)
2. 앱 설치 → 온보딩에서 키 입력
3. F8 누르고 말하면 끝

**기능:**
- F8 토글, 커서 위치에 바로 입력
- Soniox / Deepgram 선택 가능 (자기 키 사용)
- 단어사전 — 고유명사 등록하면 STT가 알아서 교정
- LLM 후처리 — DeepSeek, OpenAI, Gemini 등 연결 가능 (번역, 정리 등)
- 히스토리 300개 보관

완전 무료, 오픈소스 (MIT): https://github.com/gyujeongion/voicetype

한국어 실시간 인식은 Soniox가 현재 제일 정확합니다. 
궁금한 점 댓글로 달아주세요.
```
