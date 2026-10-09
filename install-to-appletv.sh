#!/usr/bin/env bash
#
# 一条命令：编译 KVideoTV → 签名 → 无线安装到已配对的 Apple TV
#
# 用法：
#   ./install-to-appletv.sh                 # 自动找电视
#   ./install-to-appletv.sh <设备ID>        # 指定设备（xcrun devicectl list devices 里的 Identifier）
#   TEAM_ID=XXXXXXXXXX ./install-to-appletv.sh
#
# 前置条件（缺一不可）：
#   1. 装了完整版 Xcode，且 `xcode-select -p` 指向它
#   2. Xcode → Settings → Accounts 已登录 Apple ID（免费 Personal Team 即可）
#   3. 工程 Signing 里的 Bundle Identifier 已改成自己独有的（不能是 com.example.*）
#   4. Apple TV 已在 Xcode → Window → Devices and Simulators 里配对过
#
# 免费账号签的包 7 天过期，到期重新跑一遍这个脚本即可续签。

set -euo pipefail

cd "$(dirname "$0")"

PROJECT="KVideoTV.xcodeproj"
SCHEME="KVideoTV"
CONFIGURATION="Release"
DERIVED_DATA="build"

red()    { printf '\033[31m%s\033[0m\n' "$1"; }
green()  { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 1/4 检查 Xcode
if ! xcodebuild -version >/dev/null 2>&1; then
  red "没找到完整版 Xcode（当前只有命令行工具，编译 tvOS 需要完整 Xcode）。"
  cat <<'EOF'

  1) App Store 搜索 Xcode 安装（下载约 10GB，装完占 25GB 以上）
  2) sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  3) sudo xcodebuild -runFirstLaunch
  装好后再跑本脚本。
EOF
  exit 1
fi
green "Xcode: $(xcodebuild -version | head -1)"

# ---------------------------------------------------------------- 2/4 检查签名身份
BUNDLE_ID="$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER = ' "$PROJECT/project.pbxproj" | sed 's/.*= //; s/;//' | tr -d ' ')"
if printf '%s' "$BUNDLE_ID" | grep -q '^com\.example\.'; then
  red "Bundle Identifier 还是默认的 $BUNDLE_ID，Personal Team 签不了这个。"
  cat <<'EOF'
  用 Xcode 打开工程 → TARGETS: KVideoTV → Signing & Capabilities
  把 Bundle Identifier 改成自己独有的，例如 cc.cd.oott.KVideoTV
EOF
  exit 1
fi
echo "Bundle ID: $BUNDLE_ID"

TEAM_ID="${TEAM_ID:-}"
if [ -z "$TEAM_ID" ]; then
  TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '([A-Z0-9]\{10\})' | head -1 | tr -d '()' || true)"
fi

if [ -z "$TEAM_ID" ]; then
  red "没找到可用的签名证书（本机 0 valid identities）。"
  cat <<'EOF'
  让 Xcode 先把证书生成出来：
  1) 打开 Xcode → Settings (Cmd+,) → Accounts → 左下 + → 登录 Apple ID
  2) 用 Xcode 打开本工程，Signing & Capabilities 里 Team 选你的 Personal Team
  3) 用命令行生成一次证书（无需插设备）：
       xcodebuild -project KVideoTV.xcodeproj -scheme KVideoTV \
         -destination 'generic/platform=tvOS' -allowProvisioningUpdates build
  然后再跑本脚本。
  已经知道 Team ID 的话也可以直接：TEAM_ID=你的10位TeamID ./install-to-appletv.sh
EOF
  exit 1
fi
green "Team ID: $TEAM_ID"

# ---------------------------------------------------------------- 3/4 找电视
DEVICE_ID="${1:-}"
if [ -z "$DEVICE_ID" ]; then
  LIST_JSON="$(mktemp -t kvideo-devices)"
  if xcrun devicectl list devices --json-output "$LIST_JSON" >/dev/null 2>&1; then
    DEVICE_ID="$(/usr/bin/python3 - "$LIST_JSON" <<'PY'
import json, sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

devices = data.get("result", {}).get("devices", [])

def rank(conn):
    tunnel = str(conn.get("tunnelState", "")).lower()
    if "connected" in tunnel and "disconnected" not in tunnel:
        return 2
    if "disconnected" in tunnel:
        return 0
    return 1

tvs = []
for dev in devices:
    hw = dev.get("hardwareProperties") or {}
    props = dev.get("deviceProperties") or {}
    conn = dev.get("connectionProperties") or {}
    platform = str(hw.get("platform", "")).lower()
    if platform and platform != "tvos":
        continue
    if not platform and "appletv" not in str(hw.get("deviceType", "")).lower():
        continue
    tvs.append((
        rank(conn),
        props.get("name", "Apple TV"),
        props.get("osVersionNumber", "?"),
        dev.get("identifier", ""),
    ))

labels = {2: "在线", 1: "状态未知", 0: "离线"}
tvs.sort(key=lambda item: item[0], reverse=True)
for r, name, osv, ident in tvs:
    print("%s\t%s\ttvOS %s\t%s" % (labels[r], name, osv, ident), file=sys.stderr)
if tvs:
    print(tvs[0][3])
PY
)"
  fi
  rm -f "$LIST_JSON"
fi

if [ -z "$DEVICE_ID" ]; then
  red "没找到已配对的 Apple TV。"
  cat <<'EOF'
  1) 电视：设置 → 遥控器与设备 → 远程 App 与设备（打开）
  2) Mac：Xcode → Window → Devices and Simulators → Devices
     等电视那边列出你的 Mac → 选中 → 输入电视上显示的配对码
  3) 配对成功后重跑本脚本，或手动指定：
       xcrun devicectl list devices
       ./install-to-appletv.sh <上面列出的 Identifier>
EOF
  exit 1
fi
green "目标电视: $DEVICE_ID"

# ---------------------------------------------------------------- 4/4 编译 + 安装
echo
echo "→ 编译中（首次会下载 tvOS 组件，可能几分钟）..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=tvOS,id=$DEVICE_ID" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  build

APP_PATH="$(find "$DERIVED_DATA/Build/Products" -maxdepth 2 -name "$SCHEME.app" -type d 2>/dev/null | head -1)"
if [ -z "$APP_PATH" ]; then
  red "编译产物没找到，检查上面的 xcodebuild 输出。"
  exit 1
fi
green "产物: $APP_PATH"

echo "→ 通过局域网安装到电视..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo
green "装完了。"
cat <<'EOF'
第一次打开如果提示「不受信任的开发者」：
  Apple TV → 设置 → 通用 → 设备管理 → 选中你的 Apple ID → 信任
然后再打开 App。

免费账号的包 7 天后失效（图标会变灰/打不开），重新跑一遍本脚本即可续签。
EOF
