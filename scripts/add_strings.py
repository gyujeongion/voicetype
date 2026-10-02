#!/usr/bin/env python3
"""ko/en Localizable.strings에 키 추가. 사용: add_strings.py <앵커키> key|ko|en ...
앵커 줄 바로 뒤에 넣고, 이미 있는 키는 값만 갱신한다."""
import re, sys
anchor = sys.argv[1]
items = [a.split("|") for a in sys.argv[2:]]
for lang, idx in (("ko", 1), ("en", 2)):
    p = f"Sources/VoiceType/Resources/{lang}.lproj/Localizable.strings"
    lines = open(p, encoding="utf-8").read().split("\n")
    for it in items:
        key, val = it[0], it[idx].replace('"', '\\"')
        new = f'"{key}" = "{val}";'
        hit = [i for i, l in enumerate(lines) if l.startswith(f'"{key}" =')]
        if hit:
            lines[hit[0]] = new
            continue
        pos = [i for i, l in enumerate(lines) if l.startswith(f'"{anchor}" =')]
        if not pos:
            sys.exit(f"{p}: 앵커 {anchor} 없음")
        lines.insert(pos[0] + 1, new)
        anchor_line = new  # 다음 키는 방금 넣은 키 뒤로
        anchor = key
    open(p, "w", encoding="utf-8").write("\n".join(lines))
    anchor = sys.argv[1]
print("ok")
