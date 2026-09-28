#!/bin/bash
# 面板像素快照：纯色底 + 固定种子数据，逐状态截图；重构前后逐像素比对，证明界面没变。
# 用法：
#   Scripts/panel-snapshots.sh capture <dir> [状态...]    截全部（或指定名字的）状态到 <dir>
#   Scripts/panel-snapshots.sh compare <基线dir> <新dir>  逐像素比对，有差异退出 1（差异图写在新 dir）
# 前提：先 make build；终端有「屏幕录制」权限。截图时面板会逐个闪现并抢焦点，32 张约 2 分钟。
# JTB_BIN=<路径> 可换被测二进制（拿旧版本做对照）。
# 数据写在临时目录，用假 jt，不碰真实历史和密钥库。
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=${JTB_BIN:-.build/release/jiantieban}
TOOL=.build/snaptool
if [[ ! -x $TOOL || Scripts/snaptool.swift -nt $TOOL ]]; then
  swiftc -O Scripts/snaptool.swift -o "$TOOL"
fi

# 名字:额外环境变量（值里不能有空格）。每个状态浅色、暗色各截一张，不受系统外观影响。
STATES=(
  "default:"
  "cmd:JIANTIEBAN_DEBUG_CMD=1"
  "filter:JIANTIEBAN_DEBUG_FILTER=1"
  "cmd-filter:JIANTIEBAN_DEBUG_CMD=1 JIANTIEBAN_DEBUG_FILTER=1"
  "query:JIANTIEBAN_DEBUG_QUERY=brew"
  "no-results:JIANTIEBAN_DEBUG_QUERY=zzzz"
  "expand-text:JIANTIEBAN_DEBUG_QUERY=gpt JIANTIEBAN_DEBUG_EXPAND=1"
  "expand-image:JIANTIEBAN_DEBUG_FILTER=1 JIANTIEBAN_DEBUG_EXPAND=1"
  # 按键回放（直接喂给键盘处理）：导航 / 展开 / 移走收起 / 图片上 ⌘L 无效 / 标记后改名 / 删除 / 撤销删除 /
  # 收藏（时间前出现 ★）/ 跳到末尾 / 跳回开头。cmd-o 会打开外部 App 并收起面板，不做截图状态。
  "keys-expand:JIANTIEBAN_DEBUG_KEYS=down,down,cmd-r"
  "keys-collapse:JIANTIEBAN_DEBUG_KEYS=down,down,cmd-r,down,cmd-l"
  "keys-rename:JIANTIEBAN_DEBUG_KEYS=down,cmd-l,type:Brew,field-enter"
  "keys-delete:JIANTIEBAN_DEBUG_KEYS=down,cmd-d"
  "keys-undo:JIANTIEBAN_DEBUG_KEYS=down,cmd-d,cmd-z"
  "keys-favorite:JIANTIEBAN_DEBUG_KEYS=down,cmd-s"
  "keys-jump-last:JIANTIEBAN_DEBUG_KEYS=cmd-down"
  "keys-jump-first:JIANTIEBAN_DEBUG_KEYS=cmd-down,cmd-up"
)

# 固定数据：5 条文本 + 1 张图 + 1 条密钥。假 jt 每次 add 给新引用（引用相同会撞文本去重唯一索引）
seed() {
  local home=$1
  rm -rf "$home"
  mkdir -p "$home/vault"
  cat > "$home/jt" <<EOF
#!/bin/bash
case "\$1" in
  add) n=\$(( \$(ls "$home/vault" | wc -l) + 1 )); cat > "$home/vault/r\$n"; echo "\$2 jt://secret/r\$n";;
  resolve) cat "$home/vault/\${2#jt://secret/}"; echo;;
esac
EOF
  chmod +x "$home/jt"
  "$TOOL" png "$home/seed.png"
  local run=(env JIANTIEBAN_HOME="$home" JT_BIN="$home/jt" "$BIN")
  "${run[@]}" add-text "https://developer.apple.com/design/human-interface-guidelines/" >/dev/null
  "${run[@]}" add-text "sk-proj-9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a" >/dev/null
  "${run[@]}" add-image "$home/seed.png" >/dev/null
  "${run[@]}" add-text "会议纪要：明天 10 点对齐 Q4 路线图，带上竞品分析" >/dev/null
  "${run[@]}" add-text "brew install --cask jiantieban" >/dev/null
  "${run[@]}" add-text '{"model": "gpt-5", "temperature": 0.2}' >/dev/null
  "${run[@]}" mark-secret 2 "OpenAI · prod" >/dev/null
}

capture() {
  local out=$1 home
  shift
  local only=" $* "
  mkdir -p "$out"
  home=$(mktemp -d /tmp/jtb-snap.XXXXXX)
  for entry in "${STATES[@]}"; do
    [[ $only != "  " && $only != *" ${entry%%:*} "* ]] && continue
    for look in light dark; do
      local name=${entry%%:*}-$look vars=${entry#*:} pid wid=""
      seed "$home"
      # shellcheck disable=SC2086 # vars 要按空格拆成多个 KEY=VALUE
      env JIANTIEBAN_DEBUG_SOLID=1 JIANTIEBAN_DEBUG_APPEARANCE=$look $vars JIANTIEBAN_HOME="$home" JT_BIN="$home/jt" "$BIN" _debug-panel >/dev/null 2>&1 &
      pid=$!
      for _ in $(seq 1 50); do
        wid=$("$TOOL" winid "$pid" 2>/dev/null || true)
        [[ -n $wid ]] && break
        sleep 0.1
      done
      if [[ -z $wid ]]; then
        kill "$pid" 2>/dev/null || true
        echo "$name: 面板没有出现" >&2
        exit 1
      fi
      sleep 1.2 # 等展开的 0.3s 延迟、缩略图异步解码、布局落定
      screencapture -x -o -l "$wid" "$out/$name.png"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "captured $name"
    done
  done
  rm -rf "$home"
}

compare() {
  local base=$1 new=$2 bad=0 f name
  for f in "$base"/*.png; do
    name=$(basename "$f")
    [[ $name == *.diff.png ]] && continue
    if [[ ! -f $new/$name ]]; then
      echo "${name%.png}: 新截图缺失"
      bad=1
      continue
    fi
    "$TOOL" diff "$f" "$new/$name" "$new/${name%.png}.diff.png" || bad=1
  done
  return $bad
}

case "${1:-}" in
  capture) capture "${2:?缺少输出目录}" "${@:3}" ;;
  compare) compare "${2:?缺少基线目录}" "${3:?缺少新截图目录}" ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
