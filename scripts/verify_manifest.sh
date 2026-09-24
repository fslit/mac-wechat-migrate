#!/bin/bash
# ============================================================
#  分片完整性校验：按 manifest.txt 逐片核对条目数与 sha256
# ------------------------------------------------------------
#  用法：
#      bash verify_manifest.sh <manifest.txt 所在目录>
#  或   bash verify_manifest.sh <chunks 目录>          （自动找上一级 manifest.txt）
#
#  退出码：0 全部通过 / 1 有失败 / 2 用法错误
# ============================================================

set -u

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "用法：bash verify_manifest.sh <目录>"; exit 2; }
TARGET="${TARGET%/}"

if [ -f "$TARGET/manifest.txt" ]; then
  ROOT="$TARGET"; CH="$TARGET/chunks"
elif [ -f "$(dirname "$TARGET")/manifest.txt" ]; then
  CH="$TARGET"; ROOT="$(dirname "$TARGET")"
else
  echo "✗ 找不到 manifest.txt（在 $TARGET 或它的上一级）"; exit 2
fi
MAN="$ROOT/manifest.txt"

echo "=============================================="
echo " 分片校验   $(date '+%F %T')"
echo " 清单：$MAN"
echo " 分片：$CH"
echo "=============================================="
echo

OK=0; BAD=0; MISS=0; ENTERR=0
declare -a FAILED

while read -r fn entries bytes hash rest; do
  case "$fn" in \#*|"") continue ;; esac

  if [ "$entries" = "MISSING" ]; then
    echo "  ✗ $fn  在导出时就是缺失的"
    MISS=$((MISS+1)); FAILED+=("$fn(MISSING)"); continue
  fi

  f="$CH/$fn"
  if [ ! -f "$f" ]; then
    echo "  ✗ $fn  文件不存在"
    BAD=$((BAD+1)); FAILED+=("$fn(缺失)"); continue
  fi

  # 体积是最快的判据，先卡一遍
  asz=$(stat -f %z "$f" 2>/dev/null || echo -1)
  if [ "$asz" != "$bytes" ]; then
    echo "  ✗ $fn  体积不符（清单 $bytes / 实测 $asz）"
    BAD=$((BAD+1)); FAILED+=("$fn(体积)"); continue
  fi

  # 条目数：tar 是否真的装全了
  acnt=$(tar -tf "$f" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$acnt" != "$entries" ]; then
    echo "  ✗ $fn  条目数不符（清单 $entries / 实测 $acnt）"
    ENTERR=$((ENTERR+1)); FAILED+=("$fn(条目)"); continue
  fi

  # 字节级 sha256
  ah=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
  if [ "$ah" != "$hash" ]; then
    echo "  ✗ $fn  sha256 不符（清单 ${hash:0:16}… / 实测 ${ah:0:16}…）"
    BAD=$((BAD+1)); FAILED+=("$fn(哈希)"); continue
  fi

  OK=$((OK+1))
  printf "  ✓ %-16s %6s 条目  %10s 字节\n" "$fn" "$entries" "$bytes"
done < "$MAN"

echo
echo "=============================================="
echo " 通过 $OK   体积/哈希失败 $BAD   条目失败 $ENTERR   导出时缺失 $MISS"
echo "=============================================="

if [ "$BAD" -gt 0 ] || [ "$MISS" -gt 0 ] || [ "$ENTERR" -gt 0 ]; then
  echo "有问题的分片："
  for x in "${FAILED[@]}"; do echo "  $x"; done
  echo
  echo "处理：对失败的分片重新导出（wx_export.py 会自动续传）后重传。"
  exit 1
fi

echo "全部分片校验通过，可以安全解包。"
exit 0
