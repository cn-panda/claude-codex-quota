#!/usr/bin/env bash
# 一键安装 QuotaCard：在本机编译（自动匹配 Intel / Apple Silicon）+ 建 Python 抓取环境
# + 安装到 /Applications 并启动。
set -euo pipefail
cd "$(dirname "$0")"

info() { printf "  \033[34m•\033[0m %s\n" "$*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$*"; }
die()  { printf "\n\033[31m错误：\033[0m %s\n" "$*" >&2; exit 1; }

# ── 环境检查 ──────────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || die "仅支持 macOS"
command -v swiftc  >/dev/null 2>&1 || die "未找到 swiftc，请先安装 Xcode 命令行工具：xcode-select --install"
command -v python3 >/dev/null 2>&1 || die "未找到 python3（Xcode 命令行工具自带，或 brew install python）"
ok "环境检查通过（swiftc / python3 / macOS）"

# ── 编译 + 建 venv + 打包（见 build.sh）────────────────────────────────────────
info "编译并准备运行环境（首次会建 Python venv 装依赖，稍慢）…"
bash build.sh

# ── 安装到 /Applications ──────────────────────────────────────────────────────
APP="QuotaCard.app"
DEST="/Applications/$APP"
info "安装到 /Applications…"
pkill -x QuotaCard 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true   # 去隔离属性，避免 Gatekeeper 拦
ok "已安装到 $DEST"

# ── 启动 ──────────────────────────────────────────────────────────────────────
info "启动…"
open "$DEST"
printf "\n"
ok "完成！卡片在桌面上（无 Dock 图标）。"
echo
echo "  使用提示："
echo "   • 默认直连。若你访问 claude.ai 需要代理，右键卡片 → 代理 → 自定义。"
echo "   • Claude 额度：需在 Chrome / Firefox 登录 claude.ai。"
echo "   • Codex 额度：读本地 ~/.codex/sessions，需要你用过 Codex CLI。"
echo "   • 在「主桌面」打开它，卡片会绑定到桌面、不跟进全屏 app。"
echo "   • 拖动=移动；拖边/角=缩放；右键=设置（刷新间隔 / 代理 / 开机自启 / 置顶）。"
