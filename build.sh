#!/usr/bin/env bash
# 编译 QuotaCard.app（纯 swiftc，无需 Xcode/签名）+ 准备独立的 Python 抓取环境。
set -euo pipefail
cd "$(dirname "$0")"

APP="QuotaCard.app"
EXE="QuotaCard"
SUPPORT="$HOME/Library/Application Support/QuotaCard"
VENV="$SUPPORT/venv"

echo "• 编译 Swift…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/$EXE" -framework Cocoa
cp Info.plist "$APP/Contents/Info.plist"
cp fetch.py "$APP/Contents/Resources/fetch.py"   # 抓取脚本随 app 分发

# 图标：没有 AppIcon.icns 就从 icon.swift 现生成
if [ ! -f AppIcon.icns ]; then
  echo "• 生成 app 图标…"
  swiftc -O icon.swift -o /tmp/qc-genicon -framework Cocoa
  /tmp/qc-genicon /tmp/qc-icon.png >/dev/null
  rm -rf /tmp/qc.iconset; mkdir /tmp/qc.iconset
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"             /tmp/qc-icon.png --out "/tmp/qc.iconset/icon_${s}x${s}.png"    >/dev/null
    sips -z "$((s*2))" "$((s*2))" /tmp/qc-icon.png --out "/tmp/qc.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns /tmp/qc.iconset -o AppIcon.icns
  rm -rf /tmp/qc.iconset /tmp/qc-icon.png /tmp/qc-genicon
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # app 图标

echo "• 准备 Python 抓取环境（venv + 依赖，仅首次较慢）…"
if [ ! -x "$VENV/bin/python3" ]; then
  mkdir -p "$SUPPORT"
  PY="$(command -v python3 || echo /usr/bin/python3)"
  "$PY" -m venv "$VENV"
fi
"$VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/pip" install -q browser_cookie3 curl_cffi pycryptodomex certifi >/dev/null 2>&1 || \
  echo "  ! 依赖安装失败，请手动：'$VENV/bin/pip' install browser_cookie3 curl_cffi pycryptodomex certifi"

echo "✓ 已生成 $APP"
echo "  运行： open $APP"
echo "  退出： 在卡片上右键 → 退出"
