#!/bin/bash
# ============================================================
#  雷雳直连（Thunderbolt Bridge）连通性检查
# ------------------------------------------------------------
#  只做检测，不修改任何系统设置。
#
#  用法：插好雷雳线后执行
#      bash thunderbolt-check.sh [对端雷雳IP]
#
#  能给对端 IP 就自动测连通性；不给会交互式问你要。
# ============================================================

PEER="${1:-}"

echo "=============================================="
echo " 雷雳直连检查   $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

echo
echo "[1] 雷雳线连接状态"
system_profiler SPThunderboltDataType 2>/dev/null \
  | grep -E "Bus [0-9]|Device Name:|Status:|Speed:|Receptacle" \
  | sed 's/^ *//' | sed 's/^/    /'

echo
echo "[2] 雷雳网桥地址"
BRIDGE_IP=$(ipconfig getifaddr bridge0 2>/dev/null)
if [ -n "$BRIDGE_IP" ]; then
  echo "    bridge0  IP: $BRIDGE_IP"
  case "$BRIDGE_IP" in
    169.254.*) echo "    -> 链路本地地址（APIPA 自动分配），能互通就直接用" ;;
    *)         echo "    -> 已手动配置，确认对端在同一网段" ;;
  esac
else
  echo "    bridge0 无 IP"
  echo "    -> 去 系统设置 > 网络 > 雷雳网桥 > 详细信息 > TCP/IP 手动设置"
fi
ifconfig bridge0 2>/dev/null | grep -E "status:|inet " | sed 's/^/    /'

echo
echo "[3] 物理链路成员口"
# 注意：en1/en2/en3 才是雷雳 IP 口；en4+ 可能是 USB-C 的 NCM 网口，别配错
for i in en1 en2 en3 en4; do
  ST=$(ifconfig "$i" 2>/dev/null | grep -o "status: .*" | head -1)
  if [ -n "$ST" ]; then
    MAC=$(ifconfig "$i" 2>/dev/null | grep -o "ether [0-9a-f:]*" | head -1)
    SVC=$(networksetup -listnetworkserviceorder 2>/dev/null \
          | grep -B1 "Device: $i" | head -1 | sed 's/^([0-9]*) //')
    echo "    $i  $ST  $MAC   ${SVC:+[$SVC]}"
  fi
done
echo "    提示：用 plutil -p /Library/Preferences/SystemConfiguration/NetworkInterfaces.plist"
echo "          里 IOPathMatch 是否含 AppleThunderboltIPService 来确认真雷雳口"

echo
echo "[4] 对端连通性"
if [ -z "$PEER" ] && [ -t 0 ]; then
  printf "    输入对端 Mac 的雷雳网桥 IP（回车跳过）: "
  read -r PEER
fi
if [ -n "$PEER" ]; then
  if ping -c 2 -W 2000 "$PEER" >/dev/null 2>&1; then
    echo "    $PEER 可达 ✓"
    ping -c 3 -W 2000 "$PEER" 2>/dev/null | tail -2 | sed 's/^/    /'
  else
    echo "    $PEER 不可达 ✗"
    echo "    先看路由，别先怀疑线坏了："
    route -n get "$PEER" 2>/dev/null \
      | grep -E "interface|flags|gateway" | sed 's/^/      /'
    arp -an 2>/dev/null | grep "$PEER" | sed 's/^/      /'
    echo "      ↑ flags 里出现 REJECT 就是网段被 Wi-Fi 抢走了（详见 docs/TROUBLESHOOTING.md）"
  fi
else
  echo "    已跳过"
fi

echo
echo "[5] 文件共享端口 (445)"
if netstat -an 2>/dev/null | grep -q "\.445 .*LISTEN"; then
  echo "    本机 445 正在监听 ✓  文件共享已开启"
else
  echo "    本机 445 未监听 ✗"
  echo "    去 系统设置 > 通用 > 共享 打开「文件共享」"
  echo "    并在「选项…」里勾上「使用 SMB 共享文件」（不勾会连不上）"
fi
echo "    本机共享点:"
dscl . -list /SharePoints 2>/dev/null | sed 's/^/      /'

echo
echo "[6] 网段冲突检查"
WIFI_IP=$(ipconfig getifaddr en0 2>/dev/null)
if [ -n "$WIFI_IP" ] && [ -n "$BRIDGE_IP" ]; then
  WIFI_NET=$(echo "$WIFI_IP" | cut -d. -f1-3)
  BR_NET=$(echo "$BRIDGE_IP" | cut -d. -f1-3)
  echo "    Wi-Fi(en0): $WIFI_IP"
  echo "    bridge0   : $BRIDGE_IP"
  if [ "$WIFI_NET" = "$BR_NET" ]; then
    echo "    ✗ 网段冲突！最长前缀匹配下 Wi-Fi 会赢，发往对端的包全走错接口。"
    echo "      把雷雳网桥换成独立网段，例如 172.16.99.x / 255.255.255.0"
  else
    echo "    ✓ 网段不冲突"
  fi
else
  echo "    Wi-Fi: ${WIFI_IP:-无}   bridge0: ${BRIDGE_IP:-无}   （信息不足，跳过）"
fi

echo
echo "=============================================="
echo " 下一步"
echo "  两端都设好 IP 后，在另一台 Mac 上："
echo "    访达 > 前往 > 连接服务器 (Cmd+K)"
echo "    输入 smb://${BRIDGE_IP:-<本机雷雳IP>}"
echo "    选「注册用户」，用户名填本机账号（$(whoami)）+ 本机登录密码"
echo ""
echo "  雷雳网桥静态 IP 可用以下命令设置（需管理员密码）："
echo "    sudo networksetup -setmanual \"Thunderbolt Bridge\" 172.16.99.1 255.255.255.0"
echo "=============================================="
