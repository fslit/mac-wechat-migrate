# 排障手册

本文按**症状**组织。每条都给出「现象 → 真正原因 → 怎么确认 → 怎么解决」。

所有结论都来自真机实测，不是推测。文中路径和 IP 已做脱敏，请替换为你自己的。

---

## 目录

- [A. 连不上：SMB / 雷雳直连突然失败](#a-连不上smb--雷雳直连突然失败)
- [B. 打包失败：tar 中途退出](#b-打包失败tar-中途退出)
- [C. 后台任务莫名消失](#c-后台任务莫名消失)
- [D. 传输速度异常](#d-传输速度异常)
- [E. 解包失败：文件缺失或整片报错](#e-解包失败文件缺失或整片报错)
- [F. 挂载点行为对照表](#f-挂载点行为对照表)
- [G. 诊断命令速查](#g-诊断命令速查)

---

## A. 连不上：SMB / 雷雳直连突然失败

### A.1 头号元凶：雷雳网桥和 Wi-Fi 配到了同一网段

**现象**：昨天还好，今天 `smb://192.168.x.y` 直接失败。IP 没改、线也插着。而且 **ping 是立刻失败（`No route to host`），不是超时**。

**先看路由，不要先怀疑线坏了**：

```bash
route -n get 192.168.x.y      # 关键：看 interface 和 flags
arp -an | grep 192.168.x.y    # 看是 (incomplete) 还是有 MAC
netstat -rn -f inet | head -20
```

**必现组合**：`Thunderbolt Bridge = 192.168.21.1/16`（掩码写成了 `255.255.0.0`），`Wi-Fi = 192.168.21.34/24`。

最长前缀匹配下 **/24 赢**，于是发往对端雷雳地址的包全被丢给 Wi-Fi → Wi-Fi 网段上当然没人应答 → 内核给它写一条 **REJECT 主机路由**，之后连 ping 都立刻失败：

```
route to: 192.168.21.2
 interface: en0
     flags: <UP,HOST,REJECT,DONE,LLINFO,WASCLONED,IFSCOPE,IFREF>
arp: (192.168.21.2) at (incomplete) on en0 ifscope
```

**`route -n get` 里出现 `REJECT` 就基本确诊**，线、对端、共享设置都不用再查了。

两种触发方式：

1. 雷雳网桥的掩码被从 `255.255.255.0` 改成了 `255.255.0.0`
2. 本机 Wi-Fi 连上了一个**恰好是同网段**的 LAN（换了个会议室、连了热点都可能）

**修**：换独立网段最稳。

```bash
sudo networksetup -setmanual "Thunderbolt Bridge" 192.168.99.1 255.255.255.0
sudo route delete 192.168.21.2      # 清掉那条 REJECT 缓存
```

只想快速恢复也可以把掩码改回 `/24`（此时两条路由前缀相同，靠网络服务顺序决胜负，雷雳网桥排在 Wi-Fi 前才赢——能用但脆弱）。

### A.2 第二坑：把静态 IP 配在了没有线的接口上

**现象**：设了静态 IP，但对端怎么都 ping 不通。

**原因**：`en1/en2/en3` 才是雷雳 IP 口（`AppleThunderboltIPService`），`bridge0` 就是网桥这几个；而 **`en4/en5/en6` 是 USB-C 的 NCM 网口，不是雷雳**，别把雷雳的静态 IP 配到它们上面。

一劳永逸的识别方法：

```bash
plutil -p /Library/Preferences/SystemConfiguration/NetworkInterfaces.plist \
  | grep -E 'BSD Name|IOPathMatch'
# IOPathMatch 含 AppleThunderboltIPService  → 真雷雳口
# IOPathMatch 含 AppleUSBNCMData / usb-drd   → USB-C 网络共享口

system_profiler SPThunderboltDataType | grep -E "Port|Status|Speed|Device Name"
networksetup -listnetworkserviceorder        # 服务顺序：靠前的赢平局路由
networksetup -getinfo "Thunderbolt Bridge"
```

`scripts/thunderbolt-check.sh` 的第 3 项会把这些一次性列出来。

### A.3 应急通道：走 link-local

对端雷雳/USB 网卡掉了 IP 会退回 `169.254.x.y`（APIPA）。链路层往往是通的，能直接救急：

```bash
ping -c2 169.254.x.y                  # 通 → 线和物理链路没问题
nc -z -G 2 -v 169.254.x.y 445         # 445 开着 → 对端 SMB 服务在跑
smbutil view -g //169.254.x.y         # guest 被拒 = 服务正常，只是要账号密码
```

然后访达 `Cmd+K` → `smb://169.254.x.y`。

> **判断技巧**：`smbutil view` 报 `Authentication error` 而不是 connection failed，说明**服务是好的**，别再查服务端设置了。

### A.4 判断「对端到底还在不在这个 IP 上」

路由被劫持时，`arp` 里显示 `(incomplete)` **不能**当作「对端不在」的证据——包压根没发到那条链路。**必须先清掉 REJECT 路由，再看 ARP，结论才成立。**

### A.5 SMB 连上了但对大部分路径没写权限

**现象**：能挂载、能读，但写入被拒。

**原因**：连上的是**卷根共享**，而 Apple ID / 账号凭据通常只映射到对端的同名用户主目录。

**怎么确认**：逐个路径 `touch` 测试。

```bash
M="/Volumes/你的挂载点"
for p in "$M" "$M/Users" "$M/Users/Shared" "$M/Users/$(whoami)"; do
  [ -d "$p" ] && { touch "$p/.wtest" 2>/dev/null \
    && { echo "可写 ✓ $p"; rm -f "$p/.wtest"; } || echo "只读 ✗ $p"; }
done
```

**解决**：目标目录选在 `Users/Shared` 或对端用户主目录下；或者改挂载方式，直接挂 `smb://host/用户名`（映射到主目录）而不是卷根。

**验证 445 是否在监听**（在提供服务的那台上跑）：

```bash
netstat -an | grep "\.445 .*LISTEN"
```

---

## B. 打包失败：tar 中途退出

### B.1 根因：`bsdtar` 遇到 EINTR 就放弃整个归档

**现象**：`tar -cf` 在**随机位置**中断，退出码 1，报错是这三者之一：

```
tar: Could not pack extended attributes: Interrupted system call
tar: <path>: Couldn't visit directory: Interrupted system call
tar: (null)
```

**这不是数据损坏。** 判定方法：把报错的那个目录单独打包，多跑几次，通常每次都成功。

**真正原因**：系统调用被间歇性打断（EINTR），而 `bsdtar` / libarchive **遇到就不重试，直接放弃整个归档**。

实测：同一目录单独 `tar` 5/5 成功；整包跑到 209 MB、7.5 GB、19 GB、22 GB 各挂一次，位置全不同。

**`--no-xattr --no-acl --no-mac-metadata` 只能减少一种失败模式**（扩展属性读不动），解决不了随机中断。

> 这些参数 `bsdtar` 是认的。想验证某个参数是否真的生效：
> `tar --definitely-not-an-option -cf /dev/null /etc/hosts` 会明确报 not supported。

**解决**：用分块方案（`wx_export.py`）。单片 1 万条目，失败只影响该片，重试成本可忽略。

绕开 `bsdtar` 自己的目录遍历也能降低失败粒度，但**仍会随机失败**，必须配合分块+重试：

```bash
cd "$SRC" && find . -print0 > list.bin
tar --null --no-recursion --no-xattr --no-acl --no-mac-metadata -T list.bin -cf out.tar
```

### B.2 源侧文件会消失，不能当失败

**现象**：分片报

```
tar: ./app_data/radium/web/profiles/multitab/blob_storage/<uuid>: Cannot stat: No such file or directory
```

**原因**：清单是「某一时刻」的快照。微信**退出后仍会清理** `app_data/radium/**` 里的 blob 缓存，`tar` 读到时文件已不存在。实测条目总数在一次运行中从 638061 变成 638064——这个目录一直在动。

**解决**：这类条目按「源侧已消失」折算，不计入失败：

```
期望条目数 = 本片条目数 − 消失数
```

⚠️ **另外这两行绝不能当失败判据**，否则永远重试不成功：

```
tar: Error exit delayed from previous errors.    ← 只是汇总提示
tar: (null)                                       ← 无意义输出
```

### B.3 反复删除临时文件会触发批量删除保护

**现象**：脚本突然静默退出，看不到任何异常栈。日志里只有一句：

```
[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED] count:50 threshold:50 targets:[.../part-002.tar]
```

**原因**：每次重试前删除本地临时包，累计到 **50 次**会触发宿主的批量删除保护，**把整个进程杀掉**。

**解决**：**全程复用一个临时文件名，靠 `tar -cf` / `cp` 自行截断覆盖，一次都不删。**

### B.4 判断打包是否真的成功

⚠️ **不要相信脚本自己打印的「完成」。**

很多脚本的写法是「跑完就打印完成」，无论成败：

```
... 已写入 7.6G
完成，用时 3 分 0 秒，退出码 1        ← 退出码 1 就是失败！
```

**唯一可信的判据是三项一起看：**

1. **退出码**
2. **产物体积 vs 源数据体积**（差得多就是没装全）
3. **包内条目数 vs 期望条目数**

```bash
# 体积对照
du -sh "$SRC"
ls -lh out.tar
# 条目数
tar -tf out.tar | wc -l
```

---

## C. 后台任务莫名消失

### C.1 长任务不要用 `nohup ... &` 从另一个后台任务里派生

**现象**：日志停在启动那几行，完成计数为 0，`tar` 进程消失。很容易误判成脚本有 bug。

**原因**：父后台任务一结束，用 `nohup` 派生的子进程会被一起回收。

**解决**：**直接把脚本本身作为受管后台任务启动**，或用一个能等它的前台调用兜住。

### C.2 `print` 在后台会因 `BrokenPipeError` 静默杀死进程

**原因**：后台任务的 stdout 被关闭后再 `print`，会抛 `BrokenPipeError`。

**解决**：给 `print` 套 `try/except`，并注册 `sys.excepthook` 把未捕获异常写进日志文件：

```python
import sys

def _excepthook(t, v, tb):
    import traceback
    _logf.write("!!! 未捕获异常 !!!\n"
                + "".join(traceback.format_exception(t, v, tb)))
    sys.__excepthook__(t, v, tb)

sys.excepthook = _excepthook

def say(*a):
    m = "[%s] %s" % (time.strftime("%F %T"), " ".join(map(str, a)))
    _logf.write(m + "\n")          # 日志是权威记录
    try:
        print(m)
    except Exception:
        pass                        # stdout 没了也不要崩
```

### C.3 别用 `pgrep -f "MacOS/WeChat"` 判断微信是否运行

**现象**：明明已经退出了微信，脚本却一直说「微信正在运行」。

**原因**：`pgrep -f` 匹配整条命令行，**会匹配到执行检测的那个 shell 自身**，造成误判。

**解决**：用 `pgrep -x`。

```bash
# ✗ 会自我匹配
pgrep -f "MacOS/WeChat"

# ✓ 正确
pgrep -x WeChat
```

同理，判断 tar 进程用 `pgrep -x tar` 比 `pgrep -fl "bin/tar"` 可靠。

---

## D. 传输速度异常

### D.1 小文件是「延迟受限」，不是「带宽受限」

**现象**：大文件传输飞快，但传微信目录（海量小文件）慢得离谱。

**实测对照**：

| 方式 | 实测速度 |
|---|---|
| 大文件顺序写（512 MB 单文件） | 约 **1.15 GB/s** |
| 小文件逐个写 | 约 **12 ms/文件 ≈ 66 个/秒**（≈ 2 MB/s） |

差 **500 倍**。原因是每个文件的创建都要一次网络往返，带宽根本没跑满。

**解决**：

1. **先在本机打成一个 tar，再整体写过去**——目标端看到的是一次连续大文件写入，实测可达 **42 MB/s**（63 GB 约 35–45 分钟，而逐文件拷要 12 小时以上）。
2. 如果确实无法避免「往网络盘解/拷海量小文件」，**用多路并发**把往返延迟重叠起来。实测 8 路并发可达约 **8 倍**提速。

用 `scripts/share_probe.sh` 可以量化你这块盘的小文件速度：

```bash
bash scripts/share_probe.sh /Volumes/你的挂载点
```

---

## E. 解包失败：文件缺失或整片报错

### E.1 `Operation not supported` —— 硬链接

```
tar: <path>.mp4: Can't create '<path>.mp4': Operation not supported
```

**原因**：微信数据里同一份文件常被多处引用，`bsdtar` 在归档里把它存成**硬链接**条目。**SMB 共享不支持创建硬链接**，一遇到就跳过 → 每个 mp4 / xlsx 这类大文件都可能缺失。

**这是 SMB 协议层的限制，从源端绕不过去。**

**解决**：**解包必须在目标电脑本机执行**（本机 APFS 没有这个限制）。

用 `share_probe.sh` 的第 5 项可以提前确认目标盘是否支持硬链接。

### E.2 `Operation not permitted` —— 共享盘拒绝覆盖

```
tar: <path>: Can't unlink already-existing object: Operation not permitted
```

**原因**：该共享**拒绝 unlink / 覆盖已存在的文件**（**删除被拒，新建正常**）。而 `bsdtar` 对已存在的对象会先 unlink，于是往有内容的目录里解包时整片报错。

**关键经验**：

| 操作 | 在 SMB 共享盘上的表现 |
|---|---|
| 新建文件 | 正常（几万个都没问题） |
| 覆盖 / 删除已存在文件 | **被拒** |
| 创建硬链接 | **不支持** |

**解决**：解包前把目标目录里已有内容**改名挪开**，用空目录接收数据。`wx_restore.sh` 默认就会这么做（挪到 `_解包前旧数据-<时间戳>/`，不删除，可回退）。

### E.3 大目录 `mv` 会被降级成拷贝

**现象**：想「腾出干净目录」而 `mv 目录 子目录/`，结果卡了很久，`du` 一直在涨。

**原因**：共享盘上跨目录重命名**视情况**可能退化成**拷贝**。实测一个 65 GB 目录 `mv` 花了 **11.6 分钟**（真重命名应该是瞬间）。

**解决**：在**同一父目录下改后缀**更可能走服务端 rename：

```bash
cd "$DIR" && mv app_data app_data.attempt2      # 比 mv app_data sub/ 更可能瞬时
```

**判断方法**：小样本先计时，或观察 `du` 是否在增长。如果 `mv` 期间连 `ls` 都卡住，基本就是在拷贝。

### E.4 解包后微信读不到记录

```bash
# 补权限
chmod -R u+rwX ~/Library/Containers/com.tencent.xinWeChat/Data/Documents
```

如果权限正常但仍读不到，确认：两台微信版本一致、目标机微信已登录同一账号、解包时微信确实处于退出状态。

### E.5 分片本身是否完整

解包前先验一遍，避免把传输损坏误判成解包问题：

```bash
bash scripts/verify_manifest.sh /Volumes/你的挂载点/微信数据迁移
```

---

## F. 挂载点行为对照表

不同目标盘的能力差异巨大。开工前用 `share_probe.sh` 摸清，能省几小时返工。

| 操作 | 本地 APFS | APFS 移动硬盘 | SMB 共享盘 |
|---|---|---|---|
| 新建文件 | ✓ | ✓ | ✓ |
| 覆盖 / 删除已存在文件 | ✓ | ✓ | **常被拒** |
| 创建硬链接 | ✓ | ✓ | **不支持** |
| 大文件顺序写 | 最快 | 受接口限制 | 约 1.15 GB/s（雷雳/千兆） |
| 小文件逐个写 | 快 | 快 | **约 66 个/秒**（延迟受限） |
| 跨目录重命名 | 瞬时 | 瞬时 | 视情况，可能降级成拷贝 |
| 保存扩展属性 / ACL | ✓ | ✓ | 常失败 |

**结论**：

- **打包 → 传输** 阶段：源机本机打包，整体写过去（不管是共享盘还是移动硬盘都适用）。
- **解包** 阶段：**必须在目标机本机**（尤其目标是共享盘挂载点时）。

---

## G. 诊断命令速查

```bash
# ---------- 微信与版本 ----------
pgrep -x WeChat                                        # 微信是否在运行（别用 pgrep -f）
defaults read /Applications/WeChat.app/Contents/Info.plist CFBundleShortVersionString
du -sh ~/Library/Containers/com.tencent.xinWeChat/Data/Documents

# ---------- 网络与雷雳 ----------
bash scripts/thunderbolt-check.sh 172.16.99.2
route -n get <对端IP>                                   # 看 flags 里有没有 REJECT
arp -an | grep <对端IP>
netstat -rn -f inet | head -20
networksetup -listnetworkserviceorder
plutil -p /Library/Preferences/SystemConfiguration/NetworkInterfaces.plist \
  | grep -E 'BSD Name|IOPathMatch'

# ---------- SMB 挂载 ----------
mount | grep -i smb
smbutil statshares -a                                   # SMB 版本与能力
smbutil view -g //<IP>                                  # 列共享点
nc -z -G 3 <IP> 445                                     # 445 是否通

# ---------- 进程与进度 ----------
pgrep -x tar                                            #（别用 pgrep -fl "bin/tar"）
ps -o pid,stat,%cpu,%memory,etime -p $(pgrep -x tar | head -1)

# ---------- 产物校验 ----------
tar -tf part-001.tar | wc -l                            # 条目数
shasum -a 256 part-001.tar                              # 字节级校验
awk 'NF>=4 && $1 !~ /^#/ {e+=$2; b+=$3; n++} \
     END {printf "%d 片 / %d 条目 / %.2f GB\n", n, e, b/1073741824}' manifest.txt
bash scripts/verify_manifest.sh /Volumes/你的挂载点/微信数据迁移
```

---

## 还有问题？

开 issue 时请附上：

1. macOS 版本（`sw_vers`）与芯片（`system_profiler SPHardwareDataType | head`）
2. 微信版本
3. 传输通道（雷雳 / SMB / 移动硬盘）与目标盘格式
4. **完整报错原文**（不要只描述现象）
5. `share_probe.sh` 与 `thunderbolt-check.sh` 的输出

⚠️ **提 issue 前请先脱敏**：把路径里的用户名、局域网 IP、以及任何文件名替换成占位符。不要在公开 issue 里粘贴你的真实文件清单或聊天记录路径。
