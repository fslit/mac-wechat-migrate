# mac-wechat-migrate

把 Mac 版微信的聊天数据完整迁移到另一台 Mac 的一套脚本。

核心是**分块打包 + 逐片校验 + 断点续传**，用来绕过 macOS 自带 `bsdtar` 在这类数据上会**随机位置中断、导致整包报废**的问题。

> 实测环境：macOS 26.6（Tahoe）/ Apple 芯片 / 微信 4.1.x，数据量 63 GB、63.8 万个文件。
> 最终结果：**64/64 分片全部成功，638,054 条目，sha256 逐片与清单一致，0 片丢失**。

---

## 目录

- [先读这一段](#先读这一段)
- [解决什么问题](#解决什么问题)
- [微信数据在哪](#微信数据在哪)
- [快速开始](#快速开始)
- [脚本清单](#脚本清单)
- [实测数据](#实测数据)
- [已知限制](#已知限制)
- [排障](#排障)
- [免责声明](#免责声明)

---

## 先读这一段

迁移数据是高危操作，先看清楚这四条：

1. **迁移成功并打开微信验证之前，绝对不要删源电脑上的数据。** 本工具全程只读源数据。
2. **两台电脑的微信都必须是 4.0 及以上**。4.0 是数据目录结构的分水岭，版本不一致要先升级旧的那台，并在升级后登录等数据迁移完成再操作。
3. **操作期间微信必须完全退出**（`Cmd+Q`）。烘烤运行中的 SQLite 数据库会得到不一致的数据。脚本会自己检查并在微信运行时拒绝开工。
4. **第一次用请拿一份数据副本试。** 尤其是先用 `share_probe.sh` 摸清目标盘能力——花 10 秒能省几小时返工。

---

## 解决什么问题

Mac 版微信**没有**「电脑 A 直接迁移到电脑 B」的一键功能。「设置 → 迁移与备份」里只有「备份聊天记录至电脑 / 恢复聊天记录至手机」，本质是**手机 ↔ 电脑**，官方没有电脑 ↔ 电脑通道。

所以只能手动搬数据目录。而手动搬会撞上三个坑，这套脚本就是为绕开它们写的。

### 坑 1：整包 `tar` 必然中途失败

在微信这类数据上，`tar -cf out.tar .` 会在**随机位置**中断，退出码 1，报错是这三者之一：

```
tar: Could not pack extended attributes: Interrupted system call
tar: <path>: Couldn't visit directory: Interrupted system call
tar: (null)
```

**这不是数据损坏。** 判定方法：把报错的那个目录单独打包，多跑几次——通常每次都成功。真正的含义是**系统调用被间歇性打断（EINTR），而 `bsdtar`/libarchive 遇到就不重试、直接放弃整个归档**。

实测同一目录单独 `tar` 5/5 成功；整包跑到 209 MB、7.5 GB、19 GB、22 GB 各挂一次，位置全不同。

加上 `--no-xattr --no-acl --no-mac-metadata` 只能减少一种失败模式（扩展属性读不动），**解决不了根因**仍然是随机中断。

→ 对策：**切成小片，每片独立成包、独立校验、失败自动重试**。单片 1 万条目，重试成本可忽略。

### 坑 2：走网络共享盘逐个小文件拷，慢 500 倍

微信数据的主体是几十万个小图片、语音、缩略图。走 SMB 时每个文件都要一次网络往返：

| 方式 | 实测速度 | 63 GB 需要 |
|---|---|---|
| 逐个小文件拷（访达拖拽 / `ditto` 逐目录） | **约 2.1 MB/s** | **12 小时以上** |
| 单个大文件顺序写 | **约 1.15 GB/s** | — |
| **打成 tar 后整体写过去** | **约 42 MB/s** | **35–45 分钟** |

单个文件操作是**延迟受限**（约 12 ms/文件 ≈ 66 个/秒），不是带宽受限。所以只要**在本机打成一个 tar 再写过去**，目标端看到的是一次连续大文件写入，速度直接翻 20 倍。

→ 对策：**永远不要往网络共享盘里逐文件拷微信数据；先打包成单个大文件。**

### 坑 3：从源电脑远程解包到共享盘，文件会缺

把分片直接 `tar -xf` 到另一台电脑的 SMB 共享盘上会**部分失败**，两种报错：

```
tar: <path>.mp4: Can't create '<path>.mp4': Operation not supported
tar: <path>: Can't unlink already-existing object: Operation not permitted
```

- **`Operation not supported`**：微信数据里同一份文件常被多处引用，`bsdtar` 在归档里存成**硬链接**条目。**SMB 共享不支持创建硬链接**，一遇到就跳过 → 每个 mp4/xlsx 这类大文件都可能缺失。
- **`Operation not permitted`**：该共享**拒绝 unlink/覆盖已存在的文件**（删除被拒，新建正常）。而 `bsdtar` 对已存在对象会先 unlink，于是往有内容的目录里解包时整片报错。

→ 对策：**解包一定要在目标电脑本机执行**（本机 APFS 无此限制，还快得多）。用 `scripts/wx_restore.sh`。

---

## 微信数据在哪

| 微信版本 | 数据目录 | 需要搬的东西 |
|---|---|---|
| **4.0 及以后** | `~/Library/Containers/com.tencent.xinWeChat/Data/Documents` | `xwechat_files`（聊天记录/图片/文件）**和** `app_data`（账号配置与索引），两个都要 |
| **4.0 之前** | `~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat` | 里面的 `2.0b4.0.9` 文件夹 |

> ⚠️ 网上很多老教程写的是 `~/Library/Application Support/WeChat/`，那是 Windows 或更早版本的写法，在现在的 Mac 上**不存在**。
>
> 查版本：微信左下角「设置 → 关于」，或
> `defaults read /Applications/WeChat.app/Contents/Info.plist CFBundleShortVersionString`

确认目录是否存在：

```bash
ls -la ~/Library/Containers/com.tencent.xinWeChat/Data/Documents
# 应看到 app_data、xwechat_files
```

---

## 快速开始

### 环境要求

- 两台 macOS（Intel 或 Apple 芯片均可），微信均为 **4.0+**
- 目标盘可用空间 > 数据体积 × 1.2
- Python 3（macOS 自带 `/usr/bin/python3` 即可）
- 本工具面向 **macOS 自带的 `bsdtar`**（用了 `--no-xattr` 等 BSD 专有参数），Linux 的 GNU tar 不适用

### 第 0 步：摸清目标盘能力（强烈建议）

先挂载好目标盘（见下方「选择传输通道」），然后：

```bash
bash scripts/share_probe.sh "/Volumes/你的挂载点"
```

它会花 10 秒报告：是否可写、能否覆盖已有文件、**是否支持硬链接**、大文件速度、小文件速度、SMB 协议细节。如果它告诉你「不支持硬链接」，那就**一定**不能在源电脑上远程解包，必须到目标机本机解包。

### 第 1 步：选传输通道

| 通道 | 适用 | 关键点 |
|---|---|---|
| **雷雳线直连** | 两台都有雷雳口 | 最快，不经路由器。必须是**真雷雳线**（线头/包装有闪电标 ⚡），普通 USB-C 充电线不行。两端在「系统设置 → 网络 → 雷雳网桥 → 详细信息 → TCP/IP」各设**独立网段**静态 IP，如 `172.16.99.1/24` 和 `172.16.99.2/24` |
| **SMB 共享盘** | 通用兜底 | 源机开「文件共享」时**必须在「选项…」里勾上「使用 SMB 共享文件」**，否则对端连不上。目标机访达 `Cmd+K` 连 `smb://<IP>` |
| **移动硬盘** | 大目录最稳 | 盘格式用 **APFS**，**别用 exFAT**（不保存扩展属性和符号链接） |

插好雷雳线后可以先跑一次连通性自检：

```bash
bash scripts/thunderbolt-check.sh 172.16.99.2
```

它会依次检查：雷雳总线是否识别到对端、网桥 IP、物理链路成员口、对端 ping、445 端口是否监听、以及**雷雳网段和 Wi-Fi 网段是否冲突**（这是直连失败的头号原因）。

### 第 2 步：源电脑上导出

```bash
# 微信先 Cmd+Q 完全退出
python3 scripts/wx_export.py --dest "/Volumes/迁移盘/微信数据迁移"
```

脚本会自己完成：检查微信是否退出 → `find` 生成条目清单 → 按 1 万条切片 → 逐片打包并校验条目数 → 算 sha256 → 传到目标目录 → 写 `manifest.txt`。

**中断了就直接重跑同一条命令**，已完成的片会自动跳过（断点续传）。

产物：

```
/Volumes/迁移盘/微信数据迁移/
├── chunks/
│   ├── part-001.tar
│   ├── ...
│   └── part-064.tar
└── manifest.txt        # 每片的条目数、字节数、sha256
```

### 第 3 步：目标电脑上解包

**在目标电脑本机执行**（不是源电脑）：

```bash
# 微信先 Cmd+Q 完全退出
bash scripts/wx_restore.sh \
  --src ~/微信数据迁移/chunks \
  --dest ~/Library/Containers/com.tencent.xinWeChat/Data/Documents \
  --verify
```

`--verify` 会先按 manifest 逐片核对 sha256，确认传输无损再解包。

脚本会把目标目录里已有的 `app_data` / `xwechat_files` **改名挪到 `_解包前旧数据-<时间戳>/`**（不删除，可随时回退），然后用空目录接收数据，避免覆盖冲突。

### 第 4 步：验证

打开微信登录，检查最近的聊天记录、图片、文件是否齐全。

确认无误后再回收空间：

```bash
# 目标机
rm -rf ~/Library/Containers/com.tencent.xinWeChat/Data/Documents/_解包前旧数据-*
rm -rf ~/微信数据迁移
# 源机的半成品包也一并清掉
```

---

## 脚本清单

| 脚本 | 在哪台机器跑 | 作用 |
|---|---|---|
| `scripts/share_probe.sh` | 源机 | 探测目标挂载点的读写/硬链接/覆盖能力与速度，开工前必跑 |
| `scripts/thunderbolt-check.sh` | 两台都行 | 雷雳直连连通性自检，含网段冲突检查 |
| `scripts/wx_export.py` | 源机 | 分块打包 + 逐片校验 + 上传 + 断点续传 |
| `scripts/verify_manifest.sh` | 任意 | 按 manifest 逐片核对体积/条目数/sha256 |
| `scripts/wx_restore.sh` | **目标机** | 并行解包 + 逐片重试 + 断点续传 |

常用参数：

```bash
# 更小的片（网络更不稳定时更稳）
python3 scripts/wx_export.py --dest /Volumes/盘/目标 --chunk 5000

# 目标挂载点的写小文件很慢时，提高并发
bash scripts/wx_restore.sh --src .../chunks --dest ... --workers 8

# 单独复核已传完的分片
bash scripts/verify_manifest.sh /Volumes/迁移盘/微信数据迁移

# 看完整用法
python3 scripts/wx_export.py --help
bash scripts/wx_restore.sh --help
```

---

## 实测数据

63 GB / 638,054 条目 / 64 分片，Apple 芯片 Mac + 雷雳直连 SMB：

| 阶段 | 实测 |
|---|---|
| 生成条目清单（`find`） | 约 9 分钟 |
| 分块打包 + 上传 | 约 17 分钟（约 10 片首次失败后靠重试救回，0 片最终失败） |
| 校验 | 抽取 part-001 / part-064 的 sha256，与清单完全一致 |
| 并行解包 | 4–8 路并发，比串行快约 8 倍 |

对照：同样的数据走「逐个小文件直拷」需要 12 小时以上。

---

## 已知限制

- **只支持 macOS**（依赖 `bsdtar` 的 BSD 专有参数与 `open`/APFS 语义）。
- **不做数据内容解析**：不解析聊天数据库、不导出为可读格式、不挑选部分联系人。这是整目录搬迁工具，不是聊天记录导出器。
- **依赖微信自身的加密与账号校验**：数据搬到新机后需要在同一账号下登录才能读取，工具不参与加解密。
- **硬链接条目原样保留**：所以解包必须在本机 APFS 上做。
- 目标机若从未登录过微信、目录不存在，请先打开微信登录一次让它生成目录，再跑解包。

---

## 排障

遇到「连不上」「解包报错」「速度异常」等情况，见 **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**，里面是完整的问题-原因-对策对照，包括：

- SMB / 雷雳直连突然连不上（`route -n get` 里出现 `REJECT` 的头号元凶）
- 静态 IP 配错了接口（`en1/en2/en3` 才是雷雳口）
- 解包报 `Operation not supported` / `Operation not permitted` 的真实含义
- 长任务被静默杀死的几种原因（不能用 `nohup` 从后台任务派生、批量删除保护、`BrokenPipeError`）
- 为什么不能用 `pgrep -f "MacOS/WeChat"` 判断微信是否在运行

更详细的分步操作说明见 **[docs/USAGE.md](docs/USAGE.md)**。

---

## 免责声明

本工具按「现状」提供，不附带任何形式的担保。迁移微信数据涉及你的私人通信记录，请自行承担操作风险，并在操作前确保有可用备份。

**始终保留源数据，直到你亲眼确认目标机上一切正常。**

---

## License

[MIT](LICENSE)
