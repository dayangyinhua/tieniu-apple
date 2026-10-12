#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
铁牛社区 · Apple 双端 —— 由**一张 1024×1024 源图**生成 iOS / macOS 两套 AppIcon

🔴 为什么两端不是同一套：
   · **iOS**：App Store 硬要求 1024×1024 **不能带 alpha**（PNG colortype 必须 == 2 = RGB），
     且**不能自己画圆角**（系统会裁）。⇒ 实心方形、不透明。
   · **macOS**：图标是「圆角方形 + 四周透明」，系统**不会**帮你裁圆角。
     不画圆角就是一个突兀的白方块，一眼就不像 macOS 应用。⇒ 圆角 + 透明。
   同一张源图，两套处理，别混。

🔴 macOS 那个圆角用 Big Sur 之后的官方网格比例：
   画布 1024、图形本体 824×824 居中、圆角半径 ≈ 185（≈ 本体的 22.4%）。
   不按这个比例做，Dock 里会和系统图标「不一样大」。

🔴 也不用 Xcode 14+ 的「Single Size」（只放一张 1024 让 actool 自己派生）：
   出问题时的表现是「装上去图标是白的」，而且**只在真机上看得出来**。
   老老实实把全尺寸生成好：确定、可校验、任何 Xcode 都能用。

用法（需要 Pillow）：
    <venv>/python.exe tools/make_app_icons.py --platform ios
    <venv>/python.exe tools/make_app_icons.py --platform macos
    <venv>/python.exe tools/make_app_icons.py               # 默认两端都出
"""

import argparse
import io
import json
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("ERROR: 需要 Pillow（用带 PIL 的 venv：…/.workbuddy/binaries/python/envs/default/Scripts/python.exe）")
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                       # apple-build/
SOURCE = os.path.join(HERE, "icon-source-1024.png")

IOS_SET = os.path.join(ROOT, "ios-build", "Resources", "Assets.xcassets")
MAC_SET = os.path.join(ROOT, "macos-build", "Resources", "Assets.xcassets")

# ---- iOS：18 个尺寸（filename, 像素, idiom, 点尺寸, scale）
IOS_SPEC = [
    ("icon-20@2x.png", 40, "iphone", "20x20", "2x"),
    ("icon-20@3x.png", 60, "iphone", "20x20", "3x"),
    ("icon-29@2x.png", 58, "iphone", "29x29", "2x"),
    ("icon-29@3x.png", 87, "iphone", "29x29", "3x"),
    ("icon-40@2x.png", 80, "iphone", "40x40", "2x"),
    ("icon-40@3x.png", 120, "iphone", "40x40", "3x"),
    ("icon-60@2x.png", 120, "iphone", "60x60", "2x"),
    ("icon-60@3x.png", 180, "iphone", "60x60", "3x"),
    ("icon-20.png", 20, "ipad", "20x20", "1x"),
    ("icon-20@2x~ipad.png", 40, "ipad", "20x20", "2x"),
    ("icon-29.png", 29, "ipad", "29x29", "1x"),
    ("icon-29@2x~ipad.png", 58, "ipad", "29x29", "2x"),
    ("icon-40.png", 40, "ipad", "40x40", "1x"),
    ("icon-40@2x~ipad.png", 80, "ipad", "40x40", "2x"),
    ("icon-76.png", 76, "ipad", "76x76", "1x"),
    ("icon-76@2x.png", 152, "ipad", "76x76", "2x"),
    ("icon-83.5@2x.png", 167, "ipad", "83.5x83.5", "2x"),
    ("icon-1024.png", 1024, "ios-marketing", "1024x1024", "1x"),
]

# ---- macOS：10 个尺寸（idiom 一律 mac）
MAC_SPEC = [
    ("icon_16x16.png", 16, "16x16", "1x"),
    ("icon_16x16@2x.png", 32, "16x16", "2x"),
    ("icon_32x32.png", 32, "32x32", "1x"),
    ("icon_32x32@2x.png", 64, "32x32", "2x"),
    ("icon_128x128.png", 128, "128x128", "1x"),
    ("icon_128x128@2x.png", 256, "128x128", "2x"),
    ("icon_256x256.png", 256, "256x256", "1x"),
    ("icon_256x256@2x.png", 512, "256x256", "2x"),
    ("icon_512x512.png", 512, "512x512", "1x"),
    ("icon_512x512@2x.png", 1024, "512x512", "2x"),
]

# macOS 图标网格：画布 1024 里图形本体 824，圆角 185
MAC_BODY = 824
MAC_RADIUS = 185


def png_color_type(path):
    with open(path, "rb") as f:
        d = f.read(33)
    if len(d) < 26 or d[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return d[25]          # 2 = RGB（无 alpha），6 = RGBA


def flatten_rgb(im):
    """压成不透明 RGB：有 alpha 的先垫白底再合成（直接丢 alpha 会让半透明边缘发黑）"""
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        bg = Image.new("RGB", im.size, (255, 255, 255))
        bg.paste(im, mask=im.split()[-1])
        return bg
    return im.convert("RGB")


def macos_master(src_rgb):
    """把实心方形源图做成 macOS 那套「圆角方形 + 透明边」的 1024 母版"""
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    body = src_rgb.resize((MAC_BODY, MAC_BODY), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (MAC_BODY, MAC_BODY), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, MAC_BODY - 1, MAC_BODY - 1], radius=MAC_RADIUS, fill=255)
    body.putalpha(mask)
    off = (1024 - MAC_BODY) // 2
    canvas.paste(body, (off, off), body)
    return canvas


def write_set(out_dir, appicon_dir, entries, contents_entries, want_rgb):
    os.makedirs(appicon_dir, exist_ok=True)
    with io.open(os.path.join(out_dir, "Contents.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    with io.open(os.path.join(appicon_dir, "Contents.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"images": contents_entries, "info": {"author": "xcode", "version": 1}},
                  f, ensure_ascii=False, indent=2)
        f.write("\n")
    ok = True
    for fn, im in entries:
        dst = os.path.join(appicon_dir, fn)
        im.save(dst, "PNG", optimize=True)
        ct = png_color_type(dst)
        good = (ct == 2) if want_rgb else (ct == 6)
        print("  %-22s %4d×%-4d colortype=%d %7d B%s"
              % (fn, im.size[0], im.size[1], ct, os.path.getsize(dst),
                 "" if good else "   <-- 色彩类型不对！"))
        ok = ok and good
    return ok


def main():
    ap = argparse.ArgumentParser(description="生成 iOS / macOS 的 AppIcon 全套尺寸 + Contents.json")
    ap.add_argument("--platform", choices=["ios", "macos", "both"], default="both")
    ap.add_argument("--src", default=SOURCE, help="1024×1024 源图（实心方形、不透明）")
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    if not os.path.isfile(src):
        print("ERROR: 找不到源图：%s" % src)
        return 2
    with Image.open(src) as _im:
        if _im.size != (1024, 1024):
            print("ERROR: 源图必须是 1024×1024，实际 %s" % (_im.size,))
            return 2
        base = flatten_rgb(_im)

    ok = True

    if args.platform in ("ios", "both"):
        print("\n===== iOS（实心方 · 不透明 · RGB）-> %s" % IOS_SET)
        entries = [(fn, base if px == 1024 else base.resize((px, px), Image.LANCZOS))
                   for fn, px, _i, _p, _s in IOS_SPEC]
        ce = [{"filename": fn, "idiom": idiom, "scale": scale, "size": pt}
              for fn, _px, idiom, pt, scale in IOS_SPEC]
        ok = write_set(IOS_SET, os.path.join(IOS_SET, "AppIcon.appiconset"), entries, ce,
                       want_rgb=True) and ok

    if args.platform in ("macos", "both"):
        print("\n===== macOS（圆角方 · 透明边 · RGBA）-> %s" % MAC_SET)
        master = macos_master(base)
        entries = [(fn, master if px == 1024 else master.resize((px, px), Image.LANCZOS))
                   for fn, px, _p, _s in MAC_SPEC]
        ce = [{"filename": fn, "idiom": "mac", "scale": scale, "size": pt}
              for fn, _px, pt, scale in MAC_SPEC]
        ok = write_set(MAC_SET, os.path.join(MAC_SET, "AppIcon.appiconset"), entries, ce,
                       want_rgb=False) and ok

    print("\n" + ("VERIFY_APPICON_OK" if ok else "VERIFY_APPICON_FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
