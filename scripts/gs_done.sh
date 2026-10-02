#!/bin/bash
# 모듈 상태 갱신 + LEDGER 기록 + 커밋. 사용: scripts/gs_done.sh M1 DONE "무엇 · 증거"
set -e
cd "$(dirname "$0")/.."
M="$1"; ST="$2"; MSG="$3"
python3 - "$M" "$ST" <<'PY'
import sys,re
m,st=sys.argv[1],sys.argv[2]
p=".goalset/MODULES.md"
lines=open(p).read().split("\n")
for i,l in enumerate(lines):
    if l.startswith(f"| {m} |"):
        cells=l.split("|")
        cells[4]=f" {st} "
        lines[i]="|".join(cells)
open(p,"w").write("\n".join(lines))
PY
echo "- $(date '+%Y-%m-%d %H:%M') [$M] $MSG" >> .goalset/LEDGER.md
