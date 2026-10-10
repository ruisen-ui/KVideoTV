#!/usr/bin/env python3
"""
探针：查出这版工程构建出的 ipa 在 Apple TV 上为什么没有图标。

背景：CI 构建日志里有
    The app icon set "AppIcon" has 3 unassigned children.
虽然 PNG 尺寸（400x240 / 800x480 / 1280x768）与 Contents.json 声明完全匹配。

本机（macOS + 只有 CommandLineTools）没有 actool，无法本地复现；
而 GitHub 的 job 日志匿名下载返回 403（需要 admin 权限），所以这里把全部
诊断结果打印到 stdout，由 workflow 重定向进 probe-result.txt 提交回仓库。

做两件事：
  1. 完整构建一次，解剖 .app 产物：Info.plist 有没有图标键、Assets.car 里有没有 AppIcon
  2. 用 actool 逐个试各种 Contents.json 写法，比较哪种 0 警告且真能编出 AppIcon
"""

import json
import os
import shutil
import subprocess
import sys

SRC = "KVideoTV/KVideoTV/Assets.xcassets/AppIcon.appiconset"
REPO_CATALOG = "KVideoTV/KVideoTV/Assets.xcassets"
WORK = "/tmp/probe"
ROOT_JSON = {"info": {"author": "xcode", "version": 1}}
DARK = [{"appearance": "luminosity", "value": "dark"}]


def sh(*args):
    return subprocess.run(list(args), capture_output=True, text=True)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)


# ---------------------------------------------------------------- 基线构建

def baseline():
    print("=" * 72)
    print("基线：完整构建 + 解剖产物")
    print("=" * 72)

    out = os.path.abspath("out")
    shutil.rmtree(out, ignore_errors=True)
    r = sh("xcodebuild",
           "-project", "./KVideoTV.xcodeproj",
           "-target", "KVideoTV",
           "-configuration", "Release",
           "-sdk", "appletvos",
           f"CONFIGURATION_BUILD_DIR={out}",
           "CODE_SIGNING_ALLOWED=NO",
           "CODE_SIGNING_REQUIRED=NO",
           "CODE_SIGN_IDENTITY=",
           "build")
    txt = (r.stdout or "") + (r.stderr or "")
    keys = ("error:", "warning:", "unassigned", "BUILD SUCCEEDED", "BUILD FAILED")
    print("--- 构建日志里的 error/warning ---")
    for line in txt.splitlines():
        if any(k in line for k in keys):
            print("   ", line.strip()[:220])
    print("    exit:", r.returncode)
    print()

    app = os.path.join(out, "KVideoTV.app")
    if not os.path.isdir(app):
        print("!! 没有产出 .app，后续解剖跳过")
        return
    print("--- .app 内容 ---")
    for f in sorted(os.listdir(app)):
        p = os.path.join(app, f)
        size = os.path.getsize(p) if os.path.isfile(p) else "<dir>"
        print(f"    {f:<34}{size}")

    car = os.path.join(app, "Assets.car")
    print()
    print("--- Info.plist 里的图标相关键 ---")
    pi = sh("plutil", "-p", os.path.join(app, "Info.plist"))
    hits = [l for l in (pi.stdout or "").splitlines()
            if any(k in l.lower() for k in ("icon", "appicon", "brand"))]
    print("\n".join("    " + l.strip() for l in hits) if hits
          else "    !! Info.plist 里没有任何 icon 键")

    print()
    print("--- Assets.car 内容 ---")
    if os.path.exists(car):
        print(f"    Assets.car 大小: {os.path.getsize(car)}")
        au = sh("xcrun", "--sdk", "appletvos", "assetutil", "--info", car)
        try:
            arr = json.loads(au.stdout or "[]")
            for a in arr:
                nm = a.get("Name") or a.get("AssetType") or "?"
                print(f"      {a.get('AssetType','?'):<28} {nm}")
        except Exception:
            print("      (assetutil 输出无法解析)")
            for l in (au.stdout or "").splitlines()[:30]:
                print("      ", l.strip()[:180])
    else:
        print("    !! 没有 Assets.car")
    print()


# ---------------------------------------------------------------- 图标格式实验

def prep_pngs():
    dst = os.path.join(WORK, "png")
    os.makedirs(dst, exist_ok=True)
    for n in ("400", "800", "1280"):
        shutil.copy(os.path.join(SRC, f"AppIcon-{n}.png"), os.path.join(dst, f"i{n}.png"))
    # 1280x768 @2x = 2560x1536
    sh("sips", "-z", "1536", "2560",
       os.path.join(SRC, "AppIcon-1280.png"), "--out", os.path.join(dst, "i2560.png"))
    print("--- 可用 PNG ---")
    for f in sorted(os.listdir(dst)):
        info = sh("sips", "-g", "pixelWidth", "-g", "pixelHeight", os.path.join(dst, f))
        nums = [t for t in info.stdout.split() if t.isdigit()]
        print(f"    {f:<12}{nums[0] if nums else '?':>6} x {nums[1] if len(nums) > 1 else '?'}")
    print()


def ent(fn, size, scale, appearances=None):
    d = {"filename": fn, "idiom": "tv", "scale": scale, "size": size}
    if appearances:
        d["appearances"] = appearances
    return d


CASES = {
    "C_current3": [
        ent("i400.png", "400x240", "1x"),
        ent("i800.png", "400x240", "2x"),
        ent("i1280.png", "1280x768", "1x"),
    ],
    "A_4slot": [
        ent("i400.png", "400x240", "1x"),
        ent("i800.png", "400x240", "2x"),
        ent("i1280.png", "1280x768", "1x"),
        ent("i2560.png", "1280x768", "2x"),
    ],
    "B_2x_only": [
        ent("i800.png", "400x240", "2x"),
        ent("i2560.png", "1280x768", "2x"),
    ],
    "G_1x_only": [
        ent("i400.png", "400x240", "1x"),
        ent("i1280.png", "1280x768", "1x"),
    ],
    "E_single_2x": [ent("i800.png", "400x240", "2x")],
    "F_no_scale": [
        {"filename": "i800.png", "idiom": "tv", "size": "400x240"},
        {"filename": "i1280.png", "idiom": "tv", "size": "1280x768"},
    ],
}
CASES["D_4slot_dark"] = CASES["A_4slot"] + [
    ent("i400.png", "400x240", "1x", DARK),
    ent("i800.png", "400x240", "2x", DARK),
    ent("i1280.png", "1280x768", "1x", DARK),
    ent("i2560.png", "1280x768", "2x", DARK),
]


def build_catalog(name, images, extra=None):
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


def run_actool(name, catalog, note=""):
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

    print("#" * 72)
    print(f"### {name} {note}")
    print(f"    exit={r.returncode}  警告={len(warns)} 错误={len(errs)} 其中unassigned={len(unassigned)}")
    for l in errs[:5]:
        print("    ERROR:", l.split(": ")[-1][:170])
    for l in unassigned[:3]:
        print("    ⚠ unassigned:", l.split("warning: ")[-1][:170])
    for l in [w for w in warns if w not in unassigned][:4]:
        print("    ⚠", l.split("warning: ")[-1][:170])
    if not warns and not errs:
        print("    ✅ 完全干净")

    car = os.path.join(out, "Assets.car")
    has_icon = False
    if os.path.exists(car):
        au = sh("xcrun", "--sdk", "appletvos", "assetutil", "--info", car)
        has_icon = "AppIcon" in (au.stdout or "")
        print(f"    产物: Assets.car 存在（{os.path.getsize(car)} 字节）, 含 AppIcon = {has_icon}")
    else:
        print("    产物: ❌ 没有 Assets.car")
    print()
    return {"name": name, "exit": r.returncode, "warn": len(warns), "err": len(errs),
            "unassigned": len(unassigned), "icon": has_icon}


def main():
    shutil.rmtree(WORK, ignore_errors=True)

    baseline()

    print("=" * 72)
    print("图标格式实验")
    print("=" * 72)
    prep_pngs()

    results = []
    # 直接拿仓库里现成的 catalog 跑一次，精确复现当前警告
    results.append(run_actool("I_repo_catalog", REPO_CATALOG, "（= 仓库现状，不动它）"))

    for name, images in CASES.items():
        results.append(run_actool(name, build_catalog(name, images)))

    results.append(run_actool("H_4slot_prerendered",
                              build_catalog("H_4slot_prerendered", CASES["A_4slot"],
                                            extra={"pre-rendered": True})))

    print("=" * 72)
    print("汇总")
    print("=" * 72)
    print(f"{'方案':<24}{'exit':>5}{'警告':>6}{'错误':>6}{'unassigned':>12}   含AppIcon")
    for r in results:
        print(f"{r['name']:<24}{r['exit']:>5}{r['warn']:>6}{r['err']:>6}"
              f"{r['unassigned']:>12}   {'✅' if r['icon'] else '❌'}")


if __name__ == "__main__":
    main()
