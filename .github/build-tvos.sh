#!/bin/bash
# 构建 tvOS（不签名），并验证 AppIcon 是否真的编进了 Assets.car。
#
# 背景（踩过的坑）：
#   1) xcodebuild 会用 ASSETCATALOG_COMPILER_APPICON_NAME 的值拼出 actool 的
#      --app-icon 参数。若该值与 asset catalog 里的图标集名字对不上，actool
#      只是「找不到就跳过」，构建照样成功，图标静默丢失 —— 装到电视上是白图标。
#   2) tvOS 的图标集叫 "App Icon & Top Shelf Image.brandassets"，
#      而 Xcode 模板默认值是 AppIcon。所以 pbxproj 里那一行必须显式改掉。
#      （对照真实 tvOS 项目 HeroTransitions/Hero 的 pbxproj 确认过。）
#
# 本脚本：
#   - 方案 A：用 pbxproj 里的 "App Icon & Top Shelf Image"（brandassets 分层图标栈）
#   - 方案 B：兜底生成 AppIcon.appiconset（tv idiom），用 AppIcon 名字再试一次
#   - 每个方案构建完都跑 assetutil --info 检查 Assets.car 里到底有没有 AppIcon
#   - 结果写进 .github/icon-report.md，由 workflow 提交回仓库（CI 日志读不到）
set -uo pipefail

TARGET=KVideoTV
PROJ=./KVideoTV.xcodeproj
REPORT=".github/icon-report.md"
ICONSET="$PWD/KVideoTV/Assets.xcassets"

log () { echo "$@" | tee -a "$REPORT"; }
# 把命令输出同时写进报告（log 只能接字符串，管道输出会被漏掉）
logcmd () { "$@" 2>&1 | tee -a "$REPORT"; }

: > "$REPORT"
log "# tvOS 图标诊断报告"
log ""
log "生成时间（UTC）: $(date -u '+%Y-%m-%d %H:%M:%S')"
log "Xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
log "SDK: $(xcodebuild -showsdks 2>/dev/null | grep -i tvos | head -1)"
log ""
log "## 0. asset catalog 现状"
log '```'
find "$ICONSET" -maxdepth 2 | sed "s|$ICONSET|Assets.xcassets|" | sort | tee -a "$REPORT" >/dev/null
log '```'
log ""

# 打印 Assets.car 里的 asset 名单；含 AppIcon 则返回 0
icon_report () {
  local app="$1"
  local car="$app/Assets.car"
  local n
  if [ ! -f "$car" ]; then
    log "  ✗ 没有 Assets.car"
    return 1
  fi
  n=$(/usr/bin/python3 - "$car" <<'PY'
import json, subprocess, sys
car = sys.argv[1]
arr = None
for cmd in (["xcrun", "--sdk", "appletvos", "assetutil", "--info", car],
            ["xcrun", "assetutil", "--info", car]):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0 or not (p.stdout or "").strip():
        continue
    try:
        arr = json.loads(p.stdout)
        break
    except Exception:
        continue
if arr is None:
    print("ASSETUTIL_FAIL")
    sys.exit(0)
names = [str(a.get("Name") or a.get("AssetType") or "?") for a in arr]
print("|".join(names))
PY
)
  log "  Assets.car 内容: $n"
  case "$n" in
    ASSETUTIL_FAIL)
      log "  ⚠ assetutil 不可用，改用 Info.plist / bundle 兜底判断"
      local pl="$app/Info.plist"
      if plutil -p "$pl" 2>/dev/null | grep -qiE "CFBundleIconName|CFBundleIcons"; then
        log "  ✅ Info.plist 里有图标键"
        return 0
      fi
      log "  ❌ Info.plist 里没有图标键"
      return 1
      ;;
    *Icon*|*Shelf*) return 0 ;;
    *) return 1 ;;
  esac
}

# 生成兜底的 AppIcon.appiconset（tv idiom，2 档尺寸 4 槽位）
make_appiconset () {
  local d="$ICONSET/AppIcon.appiconset"
  [ -d "$d" ] && return 0
  mkdir -p "$d"
  # 从 brandassets 的 Front 图复制过来
  local small="$ICONSET/App Icon & Top Shelf Image.brandassets/App Icon - Small.imagestack/Front.imagestacklayer/Content.imageset"
  local large="$ICONSET/App Icon & Top Shelf Image.brandassets/App Icon - Large.imagestack/Front.imagestacklayer/Content.imageset"
  cp "$small/Front.png"    "$d/AppIcon-400.png"  2>/dev/null
  cp "$small/Front@2x.png" "$d/AppIcon-800.png"  2>/dev/null
  cp "$large/Front.png"    "$d/AppIcon-1280.png" 2>/dev/null
  cp "$large/Front@2x.png" "$d/AppIcon-2560.png" 2>/dev/null
  cat > "$d/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon-400.png",  "idiom" : "tv", "scale" : "1x", "size" : "400x240" },
    { "filename" : "AppIcon-800.png",  "idiom" : "tv", "scale" : "2x", "size" : "400x240" },
    { "filename" : "AppIcon-1280.png", "idiom" : "tv", "scale" : "1x", "size" : "1280x768" },
    { "filename" : "AppIcon-2560.png", "idiom" : "tv", "scale" : "2x", "size" : "1280x768" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON
}

try_one () {
  local name="$1"; shift
  local out="$PWD/out_$name"
  rm -rf "$out"

  log "## 方案 $name"
  log '```'
  log "参数: $*"

  xcodebuild -project "$PROJ" -target "$TARGET" -configuration Release -sdk appletvos \
    CONFIGURATION_BUILD_DIR="$out" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    "$@" \
    build > "/tmp/build_$name.log" 2>&1
  local rc=$?

  log "xcodebuild exit=$rc"
  log ""
  log "-- actool 调用（看 --app-icon 的值）--"
  grep -oE '\-\-app-icon [^ ]*' "/tmp/build_$name.log" | head -3 | tee -a "$REPORT"
  log ""
  log "-- actool 警告/错误 --"
  grep -iE "unassigned|appicon|app icon|actool.*(error|warning)|error:" "/tmp/build_$name.log" \
    | head -12 | tee -a "$REPORT"
  log '```'

  if [ "$rc" -ne 0 ]; then
    log "❌ 构建失败"
    log ""
    return 1
  fi

  log "**产物内容**"
  log '```'
  ls -la "$out/$TARGET.app" 2>/dev/null | head -25 | tee -a "$REPORT"
  log ""
  log "-- Info.plist 里与图标有关的键 --"
  plutil -p "$out/$TARGET.app/Info.plist" 2>/dev/null \
    | grep -iE "Icon|CFBundleIcons|CFBundleIconName|PrimaryIcon" | tee -a "$REPORT" \
    || echo "  (没有图标相关键)" | tee -a "$REPORT"
  log ""
  log "-- bundle 根目录是否有 icon 文件 --"
  ls "$out/$TARGET.app" 2>/dev/null | grep -i icon | tee -a "$REPORT" \
    || echo "  (没有 —— tvOS 走 Assets.car，属正常)" | tee -a "$REPORT"
  log '```'
  log "**Assets.car 检查**"
  log '```'
  if icon_report "$out/$TARGET.app"; then
    log "  ✅ 图标已编入 Assets.car"
    printf '%s' "$out" > /tmp/winner
    log '```'
    log ""
    log "## 结论"
    log "方案 **$name** 成功，图标已进入 Assets.car。"
    return 0
  fi
  log "  ❌ Assets.car 里没有图标"
  log '```'
  log ""
  return 1
}

rm -f /tmp/winner

# 方案 A：pbxproj 里已设为 "App Icon & Top Shelf Image"（brandassets）
if try_one A_brandassets; then exit 0; fi

# 方案 B：兜底 —— 生成 AppIcon.appiconset 并用 AppIcon 名字
log "方案 A 失败，生成 AppIcon.appiconset 兜底重试…"
log ""
make_appiconset
if try_one B_appiconset ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon; then exit 0; fi

log "## 结论"
log "两种方案都没能让图标进入 Assets.car，需要进一步排查（见上面的 actool 输出）。"
exit 1
