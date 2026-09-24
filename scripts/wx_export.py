#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Mac 微信数据分块导出（分片打包 + 传到目标机）

为什么不能用一条 tar 命令搞定
------------------------------------------------------------------
本机 bsdtar 在整个归档被随机位置的 EINTR 打断后会放弃全部内容，表现为：

    tar: Could not pack extended attributes: Interrupted system call
    tar: <path>: Couldn't visit directory: Interrupted system call
    tar: (null)

已确认出问题的目录本身完全正常（ls 可读、单独 tar 多次成功），失败位置随机，
属于系统调用被间歇性打断，不是数据损坏。整包一次成型必然中途失败。

做法
------------------------------------------------------------------
1. find 生成条目清单，按 --chunk 条切成小片；
2. 每片单独打成一个 tar，唯一判据是「包内条目数 == 期望条目数」，再算 sha256；
3. 每片单独上传到目标目录并校验字节体积；
4. 任何一步失败自动重试（--retry 次），某片反复失败也不影响其它片；
5. 已成功的片记在 work/done.txt，重跑自动跳过 —— 可断点续传。

三个踩过的坑，改动时务必保留对应写法
------------------------------------------------------------------
a) 清单是「某一时刻」的快照。微信退出后仍会清理 radium/blob_storage 等缓存，
   导致 tar 读到时文件已不存在（Cannot stat: No such file or directory）。
   这类条目按「源侧已消失」处理，不计入失败，用 (期望 - 消失) 做校验。
   tar 的 "Error exit delayed from previous errors." / "tar: (null)" 只是
   汇总或无意义行，不能当失败判据 —— 只看条目数。

b) 反复删除本地临时包会触发宿主的批量删除保护（50 次/轮）并杀死本进程。
   因此全程只用一个临时文件名，靠 tar -cf / cp 自行截断覆盖，不做删除。

c) 库函数里写入日志要给 print 套 try/except，并注册 sys.excepthook ——
   后台任务 stdout 被关闭时 BrokenPipeError 会静默杀死进程。
"""
import argparse
import hashlib
import os
import subprocess
import sys
import time

# ---------------------------------------------------------------- 默认值

DEFAULT_SRC = os.path.expanduser(
    "~/Library/Containers/com.tencent.xinWeChat/Data/Documents")
DEFAULT_WORK = os.path.expanduser("~/.wx_export_work")
DEFAULT_CHUNK = 10000     # 每片条目数
DEFAULT_RETRY = 8         # 每片最多重试次数

# bsdtar (macOS) 的参数：跳过扩展属性 / ACL / mac 元数据，减少一种失败模式。
# 注意：本脚本面向 macOS 自带 bsdtar，GNU tar 不支持这几个选项。
TAROPT = ["--no-xattr", "--no-acl", "--no-mac-metadata"]

# 这些行只是汇总或无意义输出，绝不能当失败判据
IGNORE_ERRLINES = (b"Error exit delayed from previous errors", b"tar: (null)")

_logf = None


def say(*a):
    m = "[%s] %s" % (time.strftime("%F %T"), " ".join(str(x) for x in a))
    if _logf:
        try:
            _logf.write(m + "\n")
        except Exception:
            pass
    try:
        print(m)
    except Exception:
        pass          # 后台 stdout 被关闭时不要崩掉整脚本


def _excepthook(t, v, tb):
    import traceback
    if _logf:
        try:
            _logf.write("!!! 未捕获异常 !!!\n"
                        + "".join(traceback.format_exception(t, v, tb)))
        except Exception:
            pass
    sys.__excepthook__(t, v, tb)


sys.excepthook = _excepthook


# ---------------------------------------------------------------- 工具函数

def wechat_running():
    """判断微信是否还在运行。

    注意：绝对不要用 pgrep -f "MacOS/WeChat" —— 它会匹配到执行检测的
    shell 自身，造成「微信在运行」的误判。用 pgrep -x 或完整可执行路径。
    """
    for pat in (["pgrep", "-x", "WeChat"],
                ["pgrep", "-f", r"WeChat\.app/Contents/MacOS/WeChat"],
                ["pgrep", "-f", "WeChatAppEx"]):
        if subprocess.run(pat, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0:
            return True
    return False


def read_items(listpath):
    with open(listpath, "rb") as f:
        raw = f.read()
    items = raw.split(b"\0")
    if items and items[-1] == b"":
        items.pop()
    return items


def count_entries(tarpath):
    """tar -tf 的输出行数。这是本脚本唯一的成败判据。"""
    p = subprocess.run(["tar", "-tf", tarpath], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL)
    return p.stdout.count(b"\n")


def sha256(path, bufsize=1 << 22):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(bufsize)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def load_state(statepath):
    done = {}
    if os.path.exists(statepath):
        for line in open(statepath, encoding="utf-8"):
            p = line.split()
            if len(p) >= 3:
                done[p[0]] = (int(p[1]), p[2], int(p[3]) if len(p) > 3 else -1)
    return done


def save_state(statepath, done):
    with open(statepath, "w", encoding="utf-8") as f:
        for k in sorted(done):
            f.write("%s %d %s %d\n" % (k, done[k][0], done[k][1], done[k][2]))


# ---------------------------------------------------------------- 主流程

def build_argparser():
    ap = argparse.ArgumentParser(
        description="Mac 微信数据分块导出（分片打包 + 传到目标机）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
示例
  # 传到已挂载的共享盘 / 移动硬盘
  python3 wx_export.py --dest "/Volumes/迁移盘/微信数据迁移"

  # 换更小的片（网络更不稳定时更稳，但片数变多）
  python3 wx_export.py --dest /Volumes/迁移盘/微信数据迁移 --chunk 5000

  # 自定义源目录与工作目录
  python3 wx_export.py --src ~/wx_backup/Documents --dest /Volumes/迁移盘 --work /tmp/wxwork
""")
    ap.add_argument("--src", default=DEFAULT_SRC,
                    help="源目录（微信 Documents，默认：%(default)s）")
    ap.add_argument("--dest", required=True,
                    help="目标目录根，脚本会在其下创建 chunks/ 和 manifest.txt")
    ap.add_argument("--work", default=DEFAULT_WORK,
                    help="本机工作目录，放清单/临时包/进度（默认：%(default)s）")
    ap.add_argument("--chunk", type=int, default=DEFAULT_CHUNK,
                    help="每片条目数（默认：%(default)s）")
    ap.add_argument("--retry", type=int, default=DEFAULT_RETRY,
                    help="每片最多重试次数（默认：%(default)s）")
    ap.add_argument("--wait-wechat", type=int, default=7200,
                    help="检测到微信在运行时，最多等待多少秒（默认：%(default)s）")
    ap.add_argument("--rebuild-list", action="store_true",
                    help="强制重新生成条目清单（默认复用已有清单）")
    return ap


def main():
    global _logf
    args = build_argparser().parse_args()

    SRC = os.path.abspath(os.path.expanduser(args.src))
    DESTROOT = os.path.abspath(os.path.expanduser(args.dest))
    WORK = os.path.abspath(os.path.expanduser(args.work))
    REMDIR = os.path.join(DESTROOT, "chunks")
    LIST = os.path.join(WORK, "export_list.bin")
    STATE = os.path.join(WORK, "done.txt")
    LOG = os.path.join(WORK, "export.log")
    CHUNK = args.chunk
    MAXTRY = args.retry

    os.makedirs(WORK, exist_ok=True)
    _logf = open(LOG, "w", buffering=1)

    say("=== 微信数据分块导出 开始 ===")
    say("源目录 : %s" % SRC)
    say("目标   : %s" % REMDIR)
    say("工作区 : %s" % WORK)
    say("每片条目数: %d   每片重试上限: %d" % (CHUNK, MAXTRY))

    # ---------- 前置检查 ----------
    if not os.path.isdir(SRC):
        say("✗ 源目录不存在：%s" % SRC)
        say("  确认微信已登录过，或检查 4.0 前后的目录结构差异（见 README）。")
        return 1

    if wechat_running():
        say("检测到微信/小程序进程在运行，等待退出（最长 %d 秒，请 Cmd+Q 微信）……"
            % args.wait_wechat)
        waited = 0
        while wechat_running() and waited < args.wait_wechat:
            time.sleep(10)
            waited += 10
    if wechat_running():
        say("✗ 微信仍在运行，放弃。退出后重跑即可（已完成的片会跳过）。")
        return 2
    say("✓ 微信已退出")

    # 目标必须存在且可写 —— 共享盘没挂载时这里就能拦住
    if not os.path.isdir(DESTROOT):
        say("✗ 目标目录不存在：%s" % DESTROOT)
        say("  网络共享盘请先在访达里 Cmd+K 连上并确认挂载点。")
        return 4
    if not os.access(DESTROOT, os.W_OK):
        say("✗ 目标目录不可写：%s" % DESTROOT)
        say("  共享盘常见只读，见 docs/TROUBLESHOOTING.md「目标只读」。")
        return 4
    os.makedirs(REMDIR, exist_ok=True)
    say("✓ 目标可写")

    # ---------- 生成条目清单 ----------
    if args.rebuild_list and os.path.exists(LIST):
        os.remove(LIST)
    if not os.path.exists(LIST):
        say("生成条目清单（find，几十万条目约需 10 分钟）……")
        with open(LIST, "wb") as f:
            subprocess.run(["find", ".", "-print0"], cwd=SRC, stdout=f)
    items = read_items(LIST)
    say("条目总数: %d" % len(items))
    if len(items) < 1000:
        say("✗ 条目数异常（< 1000），终止。源目录是否选错了？")
        return 3

    chunks = [items[i:i + CHUNK] for i in range(0, len(items), CHUNK)]
    say("分片数  : %d（每片 %d 条目）" % (len(chunks), CHUNK))

    # 全程复用同一个临时文件名，靠截断覆盖，绝不删除
    # （每次重试前 os.remove 会累计触发宿主的批量删除保护并杀死进程）
    clist = os.path.join(WORK, "current.list")
    ltar = os.path.join(WORK, "current.tar")

    done = load_state(STATE)
    total = len(chunks)
    okc = failc = skipc = 0

    for idx, ch in enumerate(chunks, 1):
        name = "part-%03d.tar" % idx
        rempath = os.path.join(REMDIR, name)

        # ---------- 断点续传 ----------
        if name in done:
            size = done[name][0]
            if os.path.exists(rempath) and os.path.getsize(rempath) == size:
                if done[name][2] < 0:      # 旧状态没记条目数，从目标侧补算
                    try:
                        done[name] = (size, done[name][1], count_entries(rempath))
                        save_state(STATE, done)
                    except Exception:
                        pass
                skipc += 1
                continue
            say("%s 状态记录存在但目标文件不符，重做" % name)

        with open(clist, "wb") as f:
            f.write(b"\0".join(ch) + b"\0")

        # ---------- 打包 + 校验 ----------
        got = 0
        stale = 0
        for t in range(1, MAXTRY + 1):
            r = subprocess.run(["tar", "--null", "--no-recursion"] + TAROPT +
                               ["-T", clist, "-cf", ltar],
                               cwd=SRC, stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE)
            err = r.stderr or b""
            lines = [x for x in err.splitlines() if x.strip()]
            # 源侧已消失的条目：不计失败，只用它折减期望值
            gone = [x for x in lines if b"Cannot stat" in x
                    and b"No such file or directory" in x]
            fatal = [x for x in lines if x not in gone
                     and not any(k in x for k in IGNORE_ERRLINES)]
            if fatal:
                say("  %s 第%d次失败: %s"
                    % (name, t, fatal[0].decode("utf-8", "replace")))
                continue
            got = count_entries(ltar)
            want = len(ch) - len(gone)
            if got != want:
                say("  %s 第%d次条目数不符 %d/%d，重试" % (name, t, got, want))
                continue
            stale = len(gone)
            break
        else:
            failc += 1
            say("✗ %s 重试 %d 次仍失败，跳过（重跑可续传）" % (name, MAXTRY))
            continue

        # ---------- 上传 ----------
        # cp -X：不复制扩展属性。目标若是 SMB 共享，xattr 往往写不进去。
        size = os.path.getsize(ltar)
        h = sha256(ltar)
        up_ok = False
        for t in range(1, MAXTRY + 1):
            r = subprocess.run(["/bin/cp", "-X", ltar, rempath],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            if r.returncode == 0 and os.path.exists(rempath) \
                    and os.path.getsize(rempath) == size:
                up_ok = True
                break
            say("  %s 上传第%d次失败，重试" % (name, t))
        if not up_ok:
            failc += 1
            say("✗ %s 上传失败，下一轮重跑续传" % name)
            continue

        done[name] = (size, h, got)
        save_state(STATE, done)
        okc += 1
        pct = 100.0 * (okc + skipc) / total
        extra = ("  源侧已消失 %d 条" % stale) if stale else ""
        say("✓ %s  %d 条目  %.1f MB  (%d/%d  已完成 %.1f%%)%s"
            % (name, got, size / 1048576.0, okc + skipc, total, pct, extra))

    # ---------- 写清单到目标，供目标机逐片校验 ----------
    man = os.path.join(WORK, "manifest.txt")
    with open(man, "w", encoding="utf-8") as f:
        f.write("# 微信数据分块导出清单\n")
        f.write("# 解包请在【目标电脑本机】执行，不要从源电脑远程解包（见 README）：\n")
        f.write("#   bash scripts/wx_restore.sh --src <本目录>/chunks \\\n")
        f.write("#        --dest ~/Library/Containers/com.tencent.xinWeChat/Data/Documents\n")
        f.write("# 字段：文件名 条目数 字节数 sha256\n")
        for i in range(1, total + 1):
            n = "part-%03d.tar" % i
            if n in done:
                f.write("%s %d %d %s\n"
                        % (n, done[n][2], done[n][0], done[n][1]))
            else:
                f.write("%s MISSING\n" % n)
    try:
        subprocess.run(["/bin/cp", "-X", man, os.path.join(DESTROOT, "manifest.txt")])
    except Exception:
        pass

    say("=== 结束：成功 %d / 跳过 %d / 失败 %d，共 %d 片 ==="
        % (okc, skipc, failc, total))
    if failc:
        say("⚠️ 有 %d 片未完成，直接重跑本脚本即可续传。" % failc)
    say("清单：%s" % os.path.join(DESTROOT, "manifest.txt"))
    return 0 if failc == 0 else 5


if __name__ == "__main__":
    sys.exit(main())
