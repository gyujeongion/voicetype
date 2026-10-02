#!/usr/bin/env python3
"""설치 전후 사용자 설정 핵심 필드 보존 확인.

첫 실행(--snapshot)에 .goalset/settings_baseline.json 을 만들고,
이후 실행은 현재 settings.json 과 비교한다. 값 자체(단어사전·지시문)는 해시로만 남긴다.
"""
import hashlib
import json
import os
import sys

SETTINGS = os.path.expanduser("~/Library/Application Support/VoiceType/settings.json")
BASELINE = os.path.join(os.path.dirname(__file__), "..", ".goalset", "settings_baseline.json")


def h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()[:12]


def digest(s: dict) -> dict:
    return {
        "profiles": [
            (p["id"], p["name"], p["hotkeyKeyCode"], p["hotkeyModifiers"],
             p.get("useLLM"), p.get("triggerMode"), h(p.get("instruction", "")))
            for p in s.get("profiles", [])
        ],
        "dictionary": h(s.get("dictionary", {}).get("rawText", "")),
        "microphonePriority": s.get("microphonePriority"),
        "llm_endpoint": s.get("llm", {}).get("endpoint"),
        "llm_model": s.get("llm", {}).get("model"),
        "stt_provider": s.get("stt", {}).get("provider"),
        "spaceBar": (s.get("spaceBarTrigger"), s.get("spaceBarThreshold"),
                     s.get("spaceBarExcludedAppBundleIDs")),
        "appLanguage": s.get("appLanguage"),
        "recordingHotkey": (s.get("recordingHotkeyKeyCode"), s.get("recordingHotkeyModifiers")),
    }


def main() -> int:
    cur = digest(json.load(open(SETTINGS)))
    if "--snapshot" in sys.argv or not os.path.exists(BASELINE):
        json.dump(cur, open(BASELINE, "w"), ensure_ascii=False, indent=1)
        print("baseline 저장:", BASELINE)
        return 0
    base = json.load(open(BASELINE))
    cur = json.loads(json.dumps(cur))  # 튜플→리스트 정규화
    bad = [k for k in base if base[k] != cur.get(k)]
    if bad:
        for k in bad:
            print(f"변경됨 {k}: {base[k]} -> {cur.get(k)}")
        return 1
    print("설정 보존 OK (", len(base), "필드 )")
    return 0


if __name__ == "__main__":
    sys.exit(main())
