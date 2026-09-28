#!/bin/bash
# 性能取证：内存 + CPU 采样（全部 CLT/系统自带工具，无需 Xcode）
# 用法: Scripts/measure.sh <pid> [采样秒数]
set -euo pipefail

PID="$1"
SECS="${2:-5}"

if ! ps -p "$PID" > /dev/null; then
    echo "process $PID not found" >&2
    exit 1
fi

echo "== footprint (内存) =="
footprint -p "$PID" 2>/dev/null | head -20 || vmmap -summary "$PID" | head -20

echo ""
echo "== sample ${SECS}s (CPU 栈采样) =="
sample "$PID" "$SECS" -mayDie 2>/dev/null | sed -n '1,5p;/Analysis of sampling/,/^$/p' | head -15

echo ""
echo "== leaks =="
leaks "$PID" 2>&1 | head -5
