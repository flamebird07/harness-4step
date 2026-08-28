#!/usr/bin/env bash
# ps.sh — opencode bash → PowerShell 唯一执行入口（F-01/F-02 执行层拦截）
# 用法：scripts/ps.sh <script.ps1> [args...]
# 强制：仅 -File 模式（禁内联 -Command，杜绝 $ 展开）；脚本路径 \ → /；参数值禁止裸 $ 或 \（fail-closed）。
set -u
if [ "$#" -lt 1 ]; then echo "usage: scripts/ps.sh <script.ps1> [args...]" >&2; exit 2; fi
script="$1"; shift
script="${script//\\//}"                      # F-02: 反斜杠 → 前向斜杠（PowerShell 接受 C:/path/foo.ps1）
case "$script" in *" "*|-*)                    # F-01: 禁内联 -Command（-File 路径含空格/以-开头即拒）
  echo "ps.sh: 仅支持 -File 模式（不得内联 -Command）: $script" >&2; exit 2;;
esac
args=()
for a in "$@"; do
  case "$a" in
    *'\'*|*'$'*)                              # F-01: 参数含裸 $ 或 \ → fail-closed（防 bash 展开/路径被吃）
      echo "ps.sh: 参数含 \\ 或 \$, 禁止裸传（先赋 shell 变量或用前向斜杠）: $a" >&2; exit 2;;
  esac
  args+=("$a")
done
exec powershell.exe -NoProfile -NonInteractive -NoLogo -File "$script" "${args[@]}"
