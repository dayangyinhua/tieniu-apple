#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
铁牛社区 · Apple 双端 —— 生成 version-ios.json / version-macos.json

🔴 为什么需要它（对着铁律 94 那条「每次出安卓 APK 必写 version-android.json」）：
   客户端「关于程序」页面读的就是这份 json：
     安卓读 version-android.json · iOS 读 version-ios.json · macOS 读 version-macos.json · exe 读 version-luntan.json
   每次出包都要**一起发**，否则用户点「关于程序」看到的还是上一版说明。

字段是 **version-android.json 的超集 + 通用版（version-luntan.json）的兼容名**：
   latest_version  —— 最新版本号（客户端拿它和自己比）
   ios_url         —— ipa 文件名（iOS 客户端优先读这个）
   macos_url       —— 压缩包/映像文件名（macOS 客户端优先读这个；带 .dmg 时优先给 dmg）
   ipa_url / dmg_url —— 同义备用名，防止以后改字段时把老客户端漏掉
   download_url    —— 通用版里 exe 用的字段名，客户端会当兜底读
   md5 / size      —— 校验用
   release_notes   —— 更新说明（原样展示，可含换行）
   published_at    —— "YYYY-MM-DD HH:MM:SS"（安卓那套；网页层按这个显示「发布时间」）
   pub_date        —— "YYYY-MM-DD"（通用版那套）
   min_ios / min_macos / bundle_id / platform —— 纯标注

用法：
    python3 tools/make_version_json.py --platform ios   --file X.ipa  --version 1.0.0 --notes "说明"
    python3 tools/make_version_json.py --platform macos --file X.dmg  --version 1.0.0
    （--notes 留空 = 读 release_notes-<platform>.txt）
"""

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timedelta, timezone

# 固定 +08:00：国内用户的「发布时间」就该是北京时间。
# 不用 zoneinfo —— Windows 上常缺 tzdata，会直接抛 ZoneInfoNotFoundError。
CST = timezone(timedelta(hours=8))

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                    # apple-build/

MD5_CHUNK = 1024 * 1024

PLATFORM = {
    # platform: (输出 json 名, 主 url 字段, 允许的扩展名, 最低系统字段, 包名)
    "ios":   ("version-ios.json",   "ios_url",   (".ipa",),           "min_ios",   "com.tiemu.forum"),
    "macos": ("version-macos.json", "macos_url", (".dmg", ".zip"),    "min_macos", "com.tiemu.forum.mac"),
}


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while True:
            b = f.read(MD5_CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def read_notes(platform, explicit):
    """更新说明：命令行 --notes 优先 > release_notes-<platform>.txt > 空串。"""
    t = (explicit or "").strip()
    if t:
        return t
    fp = os.path.join(ROOT, "release_notes-%s.txt" % platform)
    if os.path.isfile(fp):
        with open(fp, "r", encoding="utf-8") as f:
            return f.read().strip()
    return ""


def main():
    ap = argparse.ArgumentParser(description="生成客户端更新配置（version-ios.json / version-macos.json）")
    ap.add_argument("--platform", required=True, choices=sorted(PLATFORM.keys()))
    ap.add_argument("--file", required=True, help="要发布的包（ios=.ipa / macos=.dmg 或 .zip）")
    ap.add_argument("--version", required=True, help="版本号，如 1.0.0")
    ap.add_argument("--notes", default="", help="更新说明（留空则读 release_notes-<platform>.txt）")
    ap.add_argument("--out", default="", help="输出路径（默认与包同目录）")
    ap.add_argument("--min-os", default="", help="最低系统版本，留空用默认")
    args = ap.parse_args()

    json_name, url_key, exts, min_key, bundle_id = PLATFORM[args.platform]

    pkg = os.path.abspath(args.file)
    if not os.path.isfile(pkg):
        print("ERROR: 找不到要发布文件：%s" % pkg)
        return 1
    low = pkg.lower()
    if not low.endswith(exts):
        print("ERROR: %s 的平台 %s 只接受 %s，收到 %s"
              % (os.path.basename(pkg), args.platform, "/".join(exts), os.path.basename(pkg)))
        return 1

    ver = args.version.strip()
    if not ver:
        print("ERROR: 版本号不能为空")
        return 1

    size = os.path.getsize(pkg)
    if size <= 0:
        print("ERROR: 文件是空的")
        return 1

    now = datetime.now(CST)
    out_name = os.path.basename(pkg)
    min_os = args.min_os.strip() or ("14.0" if args.platform == "ios" else "11.0")

    cfg = {
        "platform": args.platform,
        "bundle_id": bundle_id,
        min_key: min_os,
        "latest_version": ver,
        url_key: out_name,
        # 备用同义字段：以后改字段名时不至于把老客户端漏掉
        ("ipa_url" if args.platform == "ios" else "dmg_url"): out_name,
        "download_url": out_name,
        "md5": md5_file(pkg),
        "size": size,
        "release_notes": read_notes(args.platform, args.notes),
        "published_at": now.strftime("%Y-%m-%d %H:%M:%S"),
        "pub_date": now.strftime("%Y-%m-%d"),
    }

    out = args.out or os.path.join(os.path.dirname(pkg), json_name)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print("平台       : %s" % args.platform)
    print("发布文件    : %s" % pkg)
    print("size       : %d (%.2f MB)" % (size, size / 1048576.0))
    print("md5        : %s" % cfg["md5"])
    print("version    : %s" % ver)
    print("输出        : %s" % out)

    # ---- 自检（写成 json 再读回来对一遍）
    with open(out, "r", encoding="utf-8") as f:
        back = json.load(f)
    checks = [
        ("latest_version 正确", back.get("latest_version") == ver),
        ("%s 指向本包" % url_key, back.get(url_key) == out_name),
        ("扩展名合法", str(back.get(url_key, "")).lower().endswith(exts)),
        ("md5 是 32 位", len(str(back.get("md5", ""))) == 32),
        ("size 与文件一致且 >0", back.get("size") == size and size > 0),
        ("published_at 形如 YYYY-MM-DD HH:MM:SS", len(str(back.get("published_at", ""))) == 19),
        ("release_notes 字段存在", "release_notes" in back),
        ("pub_date 形如 YYYY-MM-DD", len(str(back.get("pub_date", ""))) == 10),
        ("download_url 兼容字段存在（客户端兜底读它）", bool(back.get("download_url"))),
        ("%s 存在" % min_key, bool(back.get(min_key))),
    ]
    bad = [n for n, ok in checks if not ok]
    for n, ok in checks:
        print("  %s %s" % ("PASS" if ok else "FAIL", n))
    print("VERIFY_VERSION_JSON_OK" if not bad else "VERIFY_VERSION_JSON_FAIL")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
