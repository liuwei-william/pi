#!/usr/bin/env bash
# 重新渲染所有架构图。用法:./render.sh [D1]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/.claude/skills/archify/bin/archify.mjs"
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p preview
for f in src/${1:-}*.json; do
  [ -e "$f" ] || continue
  type=$(node -pe "require('./$f').diagram_type")
  name=$(node -pe "require('./$f').meta.output")
  echo "→ $f  ($type)"
  # --repo-root 只支持 architecture 图(其它类型的 schema 没有 sources 字段)
  if [ "$type" = "architecture" ]; then
    node "$CLI" deliver "$type" "$f" --quality showcase --repo-root "$ROOT" >/dev/null
  else
    node "$CLI" deliver "$type" "$f" --quality showcase >/dev/null
  fi
  node "$CLI" visual-check "$name" --json >/dev/null 2>&1 || true
  [ -f "${name%.html}.visual-check.2048x1320.dark.png" ] && \
    mv "${name%.html}.visual-check.2048x1320.dark.png" "preview/${name%.html}.png"
  rm -f "${name%.html}".visual-check.*
done
echo "完成。"
