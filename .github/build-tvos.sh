#!/bin/bash
# 构建 tvOS（不签名），并自动挑出能让 Assets.car 真正带上 AppIcon 的参数组合。
#
# 背景（踩过的坑）：
#   tvOS 的 App Icon 必须用 brandassets（分层图标栈），AppIcon.appiconset 不被 tvOS 接受。
#   用 appiconset 时 actool 只报一句轻描淡写的
#       The app icon set "AppIcon" has 3 unassigned children.
#   构建照样成功，但图标压根没编进 Assets.car —— 装到 Apple TV 上就是白图标。
#
#   而 brandassets 对应的 ASSETCATALOG_COMPILER_APPICON_NAME 该填什么，
#   不同版本 Xcode 行为不一致（默认值 "AppIcon" 在 tvOS 上找不到对应的 appiconset），
#   所以这里逐个试，用 assetutil 检查 Assets.car 里到底有没有 AppIcon，取第一个成功的。
set -uo pipefail

TARGET=KVideoTV
PROJ=./KVideoTV.xcodeproj

# 打印 Assets.car 里的 asset；含 AppIcon 则返回 0
icon_report () {
  local car="$1/Assets.car"
  if [ ! -f "$car" ]; then
    echo "      !! 没有 Assets.car"
    return 1
  fi
  /usr/bin/python3 - "$car" <<'PY'
import json, subprocess, sys
car = sys.argv[1]
p = subprocess.run(["xcrun", "--sdk", "appletvos", "assetutil", "--info", car],
                   capture_output=True, text=True)
try:
    arr = json.loads(p.stdout or "[]")
except Exception:
    print("      (assetutil 输出无法解析)")
    sys.exit(1)
names = [a.get("Name") or a.get("AssetType") or "?" for a in arr]
print("      Assets.car:", ", ".join(names)[:260])
sys.exit(0 if any("AppIcon" in (a.get("Name") or "") for a in arr) else 1)
PY
}

try_one () {
  local name="$1"; shift
  local out="$PWD/out_$name"
  rm -rf "$out"
  echo "########## 方案 $name ##########"
  if [ $# -gt 0 ]; then echo "      额外参数: $*"; fi

  xcodebuild -project "$PROJ" -target "$TARGET" -configuration Release -sdk appletvos \
    CONFIGURATION_BUILD_DIR="$out" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    "$@" \
    build > "/tmp/build_$name.log" 2>&1
  local rc=$?

  echo "      xcodebuild exit=$rc"
  grep -iE "unassigned|error:|not found|warning: .*[Ii]con" "/tmp/build_$name.log" \
    | head -6 | sed 's/^/      /'
  if [ "$rc" -ne 0 ]; then
    echo "      ❌ 构建失败"
    return 1
  fi

  if icon_report "$out"; then
    echo "      ✅ 图标已编入 Assets.car"
    printf '%s' "$out" > /tmp/winner
    return 0
  fi
  echo "      ❌ Assets.car 里没有 AppIcon"
  return 1
}

rm -f /tmp/winner

try_one A_default && exit 0
try_one B_brand_name ASSETCATALOG_COMPILER_APPICON_NAME="App Icon & Top Shelf Image" && exit 0
try_one C_app_icon   ASSETCATALOG_COMPILER_APPICON_NAME="App Icon" && exit 0
try_one D_empty      ASSETCATALOG_COMPILER_APPICON_NAME= && exit 0

echo ""
echo "!!! 所有方案都没能让 Assets.car 带上 AppIcon"
for d in "$PWD"/out_*; do
  [ -d "$d" ] || continue
  echo "--- $d ---"
  ls -la "$d/KVideoTV.app" 2>/dev/null | head -20
done
exit 1
