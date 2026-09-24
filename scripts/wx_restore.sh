#!/bin/bash
# ============================================================
#  Mac 微信数据分块解包 —— 在【目标电脑本机】运行
# ============================================================
#
#  为什么必须在目标机本机跑（不要在源电脑上远程解包到共享盘）：
#    分片 tar 里含硬链接条目，SMB 网络共享不支持创建硬链接，
#    远程解包会报 "Operation not supported"，导致 mp4/xlsx 这类
#    被多处引用的大文件缺失；同时共享盘一般拒绝 unlink/覆盖已存在
#    的文件，往有内容的目录里重复解包会整片报错。
#    本机 APFS 没有这两个限制，而且快得多。
#
#  用法：
#    bash wx_restore.sh --src ~/微信数据迁移/chunks \
#         --dest ~/Library/Containers/com.tencent.xinWeChat/Data/Documents
#
#  可选：
#    --workers N     并发解包路数（默认 4；目标是网络挂载点时建议 8）
#    --verify        解包前先按 manifest.txt 校验每片 sha256
#    --keep          不挪开目标目录里的已有内容（默认会挪到
#                    _解包前旧数据-<时间戳>/，可随时回退，不删除）
#    --work DIR      进度与日志目录（默认 ~/.wx_restore_work）
#
#  特性：逐片独立解包 + 逐片重试 + 断点续传（重跑自动跳过已完成的片）
#  前提：目标电脑上的微信已完全退出（Cmd+Q）
# ============================================================

set -u

SRC=""
TGT=""
WORK="$HOME/.wx_restore_work"
WORKERS=4
DO_VERIFY=0
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --src)      SRC="$2"; shift 2 ;;
    --dest)     TGT="$2"; shift 2 ;;
    --work)     WORK="$2"; shift 2 ;;
    --workers)  WORKERS="$2"; shift 2 ;;
    --verify)   DO_VERIFY=1; shift ;;
    --keep)     KEEP=1; shift ;;
    -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "未知参数：$1（用 --help 看用法）"; exit 2 ;;
  esac
done

if [ -z "$SRC" ] || [ -z "$TGT" ]; then
  echo "✗ 必须同时指定 --src 和 --dest。用 --help 看用法。"
  exit 2
fi

SRC="${SRC/#\~/$HOME}"
TGT="${TGT/#\~/$HOME}"
WORK="${WORK/#\~/$HOME}"

DONE="$WORK/done.txt"
ERR="$WORK/errors.txt"
LOG="$WORK/restore.log"

mkdir -p "$WORK" || exit 1
touch "$DONE"
: > "$LOG"
: > "$ERR"

say() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

TS=$(date +%Y%m%d-%H%M)

say "=========================================="
say "Mac 微信数据解包   $(date '+%F %T')"
say "=========================================="
say "分片来源: $SRC"
say "解包目标: $TGT"
say "并发路数: $WORKERS"

# ---------- 0. 前置检查 ----------
# 用 pgrep -x，不要用 pgrep -f "MacOS/WeChat"（会匹配到自身 shell）
if pgrep -x WeChat >/dev/null 2>&1; then
  say "✗ 微信正在运行。请先 Cmd+Q 完全退出，再重新运行本脚本。"
  exit 1
fi
say "✓ 微信未运行"

[ -d "$SRC" ] || { say "✗ 找不到分片目录：$SRC"; exit 1; }

NUM=$(ls -1 "$SRC"/part-*.tar 2>/dev/null | wc -l | tr -d ' ')
say "分片数：$NUM"
[ "$NUM" -gt 0 ] || { say "✗ 分片为空"; exit 1; }

if [ ! -d "$TGT" ]; then
  say "✗ 找不到微信数据目录：$TGT"
  say "  请先在这台电脑上打开一次微信并登录，让它生成该目录，然后重跑本脚本。"
  exit 1
fi

# ---------- 0b. 可选：按 manifest 校验分片完整性 ----------
if [ "$DO_VERIFY" -eq 1 ]; then
  MAN="$(dirname "$SRC")/manifest.txt"
  if [ ! -f "$MAN" ]; then
    say "⚠ 未找到 manifest.txt（$MAN），跳过校验"
  else
    say "按 manifest 校验分片 sha256……"
    VBAD=0
    while read -r fn entries bytes hash; do
      case "$fn" in \#*|"") continue ;; esac
      if [ "$entries" = "MISSING" ]; then
        say "  MISSING $fn"; VBAD=$((VBAD+1)); continue
      fi
      f="$SRC/$fn"
      [ -f "$f" ] || { say "  ✗ 缺文件 $fn"; VBAD=$((VBAD+1)); continue; }
      a=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
      if [ "$a" = "$hash" ]; then
        say "  ✓ $fn"
      else
        say "  ✗ $fn 哈希不符（清单 ${hash:0:16}… / 实测 ${a:0:16}…）"
        VBAD=$((VBAD+1))
      fi
    done < "$MAN"
    if [ "$VBAD" -gt 0 ]; then
      say "✗ 有 $VBAD 片校验不通过，建议先重新传输这些片再解包。"
      exit 3
    fi
    say "✓ 全部分片校验通过"
  fi
fi

# ---------- 1. 把目标目录里已有内容挪开（不删除，可回退）----------
if [ "$KEEP" -eq 0 ]; then
  cd "$TGT" || exit 1
  DISC="_解包前旧数据-$TS"
  mkdir -p "$DISC"
  for n in app_data xwechat_files ".DS_Store"; do
    [ -e "$n" ] && mv "$n" "$DISC/" 2>/dev/null && say "  已挪开：$n → $DISC/"
  done
  cd - >/dev/null || true
  say "已有内容已挪到 $TGT/$DISC（确认无误后可删除）"
else
  say "--keep 已指定，保留目标目录现有内容（注意：可能触发共享盘/已存在文件冲突）"
fi

# ---------- 2. 逐片并行解包 ----------
# 只忽略「并行时目录已被其它片建好」这一种良性提示，其余一律视为失败。
extract_one() {
  local f="$1" n t err fatal
  n=$(basename "$f")
  for t in 1 2 3; do
    err=$(tar -xf "$f" -C "$TGT" 2>&1 >/dev/null)
    fatal=$(printf '%s\n' "$err" \
      | grep -v -e 'File exists' \
                -e 'Error exit delayed' \
                -e '^$' | head -1)
    if [ -z "$fatal" ]; then
      echo "$n" >> "$DONE"
      return 0
    fi
    echo "$n 第 $t 次失败: $fatal" >> "$ERR"
    sleep 2
  done
  return 1
}
export -f extract_one
export TGT DONE ERR

say ""
say "开始解包……"
T0=$(date +%s)

for f in "$SRC"/part-*.tar; do
  [ -f "$f" ] || continue
  n=$(basename "$f")
  if grep -qx "$n" "$DONE" 2>/dev/null; then
    say "  跳过已完成: $n"
    continue
  fi
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$WORKERS" ]; do sleep 1; done
  ( extract_one "$f" || echo "$n FAILED" >> "$ERR" ) &
done
wait

T1=$(date +%s)
OK=$(wc -l < "$DONE" | tr -d ' ')

# ---------- 3. 结果 ----------
say ""
say "=========================================="
say "解包结束：已完成 $OK / $NUM 片，用时 $(( (T1-T0)/60 )) 分 $(( (T1-T0)%60 )) 秒"
say "目标体积：$(du -sh "$TGT" 2>/dev/null | cut -f1)"
say "目录内容：$(ls -1 "$TGT" 2>/dev/null | tr '\n' ' ')"
say ""

if [ "$OK" -lt "$NUM" ]; then
  say "⚠ 有 $((NUM-OK)) 片未完成，明细见 $ERR"
  say "  重跑本脚本会自动跳过已完成的片，继续解剩余部分。"
  exit 4
fi

say "现在可以打开微信登录，检查聊天记录、图片、文件是否齐全。"
say "确认无误后可以删除这几处回收空间："
say "  $TGT/_解包前旧数据-*"
say "  $SRC"
say "  $(dirname "$SRC")/manifest.txt"
say "日志：$LOG"
say "=========================================="
