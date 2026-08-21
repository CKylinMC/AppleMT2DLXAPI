#!/usr/bin/env bash
# sign-release.sh —— 分发前对 .app 整包统一 adhoc 深重签并校验。
# 用法: sign-release.sh <path/to/App.app>
#
# 背景：SPM binaryTarget 嵌入的 Sparkle.framework 自带独立 adhoc 密封，而
# Release 主程序为 adhoc + hardened runtime。hardened runtime 会触发 dyld 库
# 校验，两次独立 adhoc 签名被判 "different Team IDs"，启动瞬间崩溃。
#
# 修复：--deep 由内而外一次性重签全部嵌套组件（Sparkle.framework 及其
# XPCServices/Updater.app/Autoupdate）。注意：绝不能附加 --options runtime——
# 已实测保留 runtime 标志仍会被 dyld 拒绝；去除后库校验不再强制，adhoc 分发
# 场景也不依赖 hardened runtime（Sparkle 官方文档同此结论）。
#
# 未来若改用 Developer ID 签名 + 公证，需改为逐组件由内而外签名并恢复
# hardened runtime（Apple 不建议对真实证书使用 --deep）。
set -euo pipefail

die() { echo "错误：$*" >&2; exit 1; }

APP="${1:?用法: sign-release.sh <path/to/App.app>}"
[[ -d "$APP" ]] || die "未找到 $APP"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

INFO="$(codesign -dvv "$APP" 2>&1)"
printf '%s\n' "$INFO" | grep -E 'Identifier|Signature|flags|TeamIdentifier'
# 防御性断言：确认 runtime 标志确已去除，防止未来 codesign 行为变化导致回归
if grep -q 'flags=.*runtime' <<< "$INFO"; then
    die "重签后仍带 runtime 标志，dyld 库校验将拒绝加载内嵌框架"
fi

echo "统一重签完成：$APP"
