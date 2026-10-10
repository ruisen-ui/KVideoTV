#!/usr/bin/env python3
"""
探针：找出 Xcode 的 actool 真正认可的 tvOS App Icon 资源写法。

背景：CI 构建日志里有
    The app icon set "AppIcon" has 3 unassigned children.
虽然 PNG 尺寸（400x240 / 800x480 / 1280x768）与 Contents.json 声明完全匹配，
结果装到 Apple TV 上的 ipa 却没有图标。

本机（macOS + 只有 CommandLineTools）没有 actool，无法本地复现，
所以在 GitHub Actions 的 macOS runner 上一次性把各种候选格式全跑一遍，
直接比较哪种格式 0 警告、且产出的 Assets.car 里真的含 AppIcon。
"""

import json
import os
import shutil
import subprocess
import sys

SRC = "KVideoTV/KVideoTV/Assets.xcassets/AppIcon.appiconset"
WORK = "/tmp/probe"
ROOT_JSON = {"info": {"author": "xcode", "version": 1}}
DARK = [{"appearance": "luminosity", "value": "dark"}]


def sh(*args):
    return subprocess.run(list(args), capture_output=True, text=True)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)


def prep_pngs():
    dst = os.path.join(WORK, "png")
    os.makedirs(dst, exist_ok=True)
    for n in ("400", "800", "1280"):
        shutil.copy(os.path.join(SRC, f"AppIcon-{n}.png"), os.path.join(dst, f"i{n}.png"))
    # 1280x768 @2x = 2560x1536
    r = sh("sips", "-z", "1536", "2560",
           os.path.join(SRC, "AppIcon-1280.png"),
           "--out", os.path.join(dst, "i2560.png"))
    if r.returncode != 0:
        print("!! 生成 2560x1536 失败:", r.stderr)
        sys.exit(1)
    print("===== 可用 PNG =====")
    for f in sorted(os.listdir(dst)):
        info = sh("sips", "-g", "pixelWidth", "-g", "pixelHeight", os.path.join(dst, f))
        nums = [t for t in info.stdout.split() if t.isdigit()]
        print(f"   {f:12s} {nums[0] if nums else '?'} x {nums[1] if len(nums) > 1 else '?'}")
    print()


def ent(fn, size, scale, appearances=None):
    d = {"filename": fn, "idiom": "tv", "scale": scale, "size": size}
    if appearances:
        d["appearances"] = appearances
    return d


CASES = {
    # 现状：3 个槽位
    "C_current3": [
        ent("i400.png", "400x240", "1x"),
        ent("i800.png", "400x240", "2x"),
        ent("i1280.png", "1280x768", "1x"),
    ],
    # 4 个槽位（补上 1280x768 @2x）
    "A_4slot": [
        ent("i400.png", "400x240", "1x"),
        ent("i800.png", "400x240", "2x"),
        ent("i1280.png", "1280x768", "1x"),
        ent("i2560.png", "1280x768", "2x"),
    ],
    # 只要 @2x 两档
    "B_2x_only": [
        ent("i800.png", "400x240", "2x"),
        ent("i2560.png", "1280x768", "2x"),
    ],
    # 只要 @1x 两档
    "G_1x_only": [
        ent("i400.png", "400x240", "1x"),
        ent("i1280.png", "1280x768", "1x"),
    ],
    # 单档 400x240 @2x
    "E_single_2x": [ent("i800.png", "400x240", "2x")],
    # 不带 scale 键
    "F_no_scale": [
        {"filename": "i800.png", "idiom": "tv", "size": "400x240"},
        {"filename": "i1280.png", "idiom": "tv", "size": "1280x768"},
    ],
}
# 4 槽位 + 深色外观各一份
CASES["D_4slot_dark"] = CASES["A_4slot"] + [
    ent("i400.png", "400x240", "1x", DARK),
    ent("i800.png", "400x240", "2x", DARK),
    ent("i1280.png", "1280x768", "1x", DARK),
    ent("i2560.png", "1280x768", "2x", DARK),
]


def build_catalog(name, images, extra=None):
    """生成 Assets.xcassets/AppIcon.appiconset，返回 catalog 目录。"""
    cat = os.path.join(WORK, "cat_" + name, "Assets.xcassets")
    shutil.rmtree(os.path.dirname(cat), ignore_errors=True)
    write_json(os.path.join(cat, "Contents.json"), ROOT_JSON)
    setd = os.path.join(cat, "AppIcon.appiconset")
    os.makedirs(setd, exist_ok=True)
    for f in os.listdir(os.path.join(WORK, "png")):
        shutil.copy(os.path.join(WORK, "png", f), os.path.join(setd, f))
    obj = {"images": images, "info": {"author": "xcode", "version": 1}}
    if extra:
        obj["properties"] = extra
    write_json(os.path.join(setd, "Contents.json"), obj)
    return cat


def run_actool(name, catalog):
    out = os.path.join(WORK, "out_" + name)
    shutil.rmtree(out, ignore_errors=True)
    r = sh("xcrun", "--sdk", "appletvos", "actool", catalog,
           "--compile", out,
           "--platform", "appletvos",
           "--target-device", "tv",
           "--minimum-deployment-target", "16.0",
           "--app-icon", "AppIcon",
           "--output-format", "human-readable-text",
           "--notices", "--warnings")

    txt = (r.stdout or "") + (r.stderr or "")
    warns = [l.strip() for l in txt.splitlines() if "warning:" in l.lower()]
    errs = [l.strip() for l in txt.splitlines() if "error:" in l.lower()]
    unassigned = [l for l in warns if "unassigned" in l.lower()]

    print("#" * 68)
    print(f"### {name}   (exit {r.returncode})")
    cat_json = json.load(open(os.path.join(catalog, "AppIcon.appiconset", "Contents.json")))
    print(f"    声明槽位: {len(cat_json['images'])} 条; 目录 PNG: "
          f"{len([f for f in os.listdir(os.path.join(catalog,'AppIcon.appiconset')) if f.endswith('.png')])} 个")
    if errs:
        for l in errs[:6]:
            print("    ERROR:", l.split(": ")[-1][:160])
    if unassigned:
        for l in unassigned[:3]:
            print("    ⚠️ unassigned:", l.split("warning: ")[-1][:160])
    other = [l for l in warns if l not in unassigned]
    for l in other[:4]:
        print("    ⚠️", l.split("warning: ")[-1][:160])
    if not errs and not warns:
        print("    ✅ 无警告无错误")

    # 产物里有没有 AppIcon
    car = os.path.join(out, "Assets.car")
    if os.path.exists(car):
        info = sh("xcrun", "--sdk", "appletvos", "assetutil", "--info", car)
        has = "AppIcon" in (info.stdout or "")
        print(f"    产物: Assets.car 存在, 含 AppIcon = {has}")
    else:
        print("    产物: ❌ 没有 Assets.car")
    print()
    return {"name": name, "exit": r.returncode,
            "unassigned": len(unassigned), "warnings": len(warns), "errors": len(errs),
            "car_has_icon": os.path.exists(car)}


def main():
    shutil.rmtree(WORK, ignore_errors=True)
    prep_pngs()

    results = []
    for name, images in CASES.items():
        results.append(run_actool(name, build_catalog(name, images)))

    # 附加：给 4 槽位版本加 properties
    results.append(run_actool("H_4slot_prerendered",
                              build_catalog("H_4slot_prerendered", CASES["A_4slot"],
                                            extra={"pre-rendered": True})))

    print("=" * 68)
    print("汇总")
    print("=" * 68)
    print(f"{'方案':<22}{'exit':>5}{'unassigned':>12}{'warning':>9}{'error':>7}  含AppIcon")
    for r in results:
        print(f"{r['name']:<22}{r['exit']:>5}{r['unassigned']:>12}{r['warnings']:>9}"
              f"{r['errors']:>7}  {'✅' if r['car_has_icon'] else '❌'}")


if __name__ == "__main__":
    main()
