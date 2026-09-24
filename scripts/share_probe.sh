#!/bin/bash
# ============================================================
#  挂载点能力探测：在真正开始搬数据之前，先摸清目标盘能做什么
# ------------------------------------------------------------
#  用法：
#      bash share_probe.sh /Volumes/你的挂载点
#
#  为什么需要它：
#    同样一个「已挂载的目录」，本地 APFS、USB 移动硬盘、SMB 网络共享
#    的能力差别巨大。先花 10 秒探测，能省掉几小时的返工：
#      - 只读挂载？写不进去，白跑。
#      - 拒绝覆盖已有文件？往有内容的目录重复解包会整片报错。
#      - 不支持硬链接？微信数据里被多处引用的 mp4/xlsx 会缺。
#      - 写小文件极慢？说明是延迟受限，必须先打包成单个大文件再传。
#
#  本脚本只读探测：写入的测试文件会在结束时清掉，不动你任何数据。
# ============================================================

set -u

M="${1:-}"
[ -n "$M" ] || { echo "用法：bash share_probe.sh <挂载点>"; exit 2; }
M="${M%/}"

[ -d "$M" ] || { echo "✗ 目录不存在：$M"; exit 2; }

echo "=============================================="
echo " 挂载点能力探测   $(date '+%F %T')"
echo " 目标：$M"
echo "=============================================="

echo
echo "[1] 挂载信息"
mount | grep -i -- "$M" | sed 's/^/    /' || echo "    （mount 里没有，可能是本地卷）"
df -h "$M" 2>/dev/null | tail -1 | sed 's/^/    /'

echo
echo "[2] 读写权限"
if [ -w "$M" ]; then echo "    可写 ✓"; else echo "    只读 ✗（共享可能设成了只读，或挂载时带 read-only）"; fi

PROBE="$M/._wb_probe_$$"
if mkdir "$PROBE" 2>/dev/null; then
  echo "    可建目录 ✓"
else
  echo "    建目录失败 ✗  后续测试跳过"
  echo "    常见原因：卷根只读，改用 //主机/用户名 共享（映射到主目录）再试"
  exit 1
fi
cleanup() { rm -rf "$PROBE" 2>/dev/null; }
trap cleanup EXIT

echo
echo "[3] 新建文件"
if printf 'hello' > "$PROBE/a.txt" 2>/dev/null; then
  echo "    新建文件 ✓"
else
  echo "    新建文件 ✗  这个盘基本不能用，换通道"
  exit 1
fi

echo
echo "[4] 覆盖/删除已存在文件（决定能否往有内容的目录重复解包）"
if printf 'world' > "$PROBE/a.txt" 2>/dev/null; then
  echo "    覆盖写 ✓"
else
  echo "    覆盖写 ✗（Operation not permitted 之类）"
  echo "    → 后果：往已有内容的目录里重复解包会整片报错"
  echo "    → 对策：解包前先把已有内容改名挪开，用空目录接收"
fi
if rm -f "$PROBE/a.txt" 2>/dev/null; then
  echo "    删除 ✓"
else
  echo "    删除 ✗"
  echo "    → 对策：不要在脚本里依赖 rm；用「同名覆盖/截断」代替删除"
fi

echo
echo "[5] 硬链接支持（决定 mp4/xlsx 这类被多处引用的文件会不会缺）"
printf 'x' > "$PROBE/h1" 2>/dev/null
if ln "$PROBE/h1" "$PROBE/h2" 2>/dev/null; then
  echo "    硬链接 ✓"
else
  echo "    硬链接 ✗（Operation not supported）"
  echo "    → 后果：从别的机器远程解包到本盘，硬链接条目会被跳过，"
  echo "      被多处引用的 mp4 / xlsx 可能缺失"
  echo "    → 对策：解包必须在目标机【本机】执行，不要在源机远程解包到共享盘"
fi

echo
echo "[6] 大文件顺序写速度（判断是否带宽充裕）"
if dd if=/dev/zero of="$PROBE/big.bin" bs=1m count=512 2>/dev/null; then
  R=$(dd if=/dev/zero of="$PROBE/big2.bin" bs=1m count=512 2>&1 | tail -1 \
      | sed 's/.*, //' | sed 's/ .*//')
  echo "    写入 512 MB 完成，参考吞吐：${R:-未知} MB/s"
else
  echo "    大文件写入失败 ✗"
fi

echo
echo "[7] 小文件写入速度（这才是微信数据的真实瓶颈）"
SF=$(seq 1 200)
S=$(date +%s)
for i in $SF; do printf 'x%.0s' {1..4000} > "$PROBE/s$i.bin" 2>/dev/null; done
E=$(date +%s)
D=$(( E - S )); [ "$D" -eq 0 ] && D=1
echo "    200 个 4KB 文件耗时 ${D} 秒 → $(( 200 / D )) 个/秒"
echo "    按 63 万个文件估算：约 $(( 630000 / (200 / D) / 60 )) 分钟"
if [ "$(( 200 / D ))" -lt 300 ]; then
  echo "    → 小文件很慢（延迟受限）。务必先在本机打成单个 tar 再传，"
  echo "      并对「往该盘解海量小文件」使用多路并发（wx_restore.sh --workers 8）"
fi

echo
echo "[8] SMB 协议细节（仅网络挂载时可用）"
if command -v smbutil >/dev/null 2>&1; then
  smbutil statshares -a 2>/dev/null | head -20 | sed 's/^/    /' \
    || echo "    （非 SMB 挂载或不可用）"
fi

echo
echo "=============================================="
echo " 探测完毕，测试文件已清理。"
echo " 根据上面的结果选通道与脚本参数，见 README 的「选择传输通道」。"
echo "=============================================="
