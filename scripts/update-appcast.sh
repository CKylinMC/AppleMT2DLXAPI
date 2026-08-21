#!/usr/bin/env bash
# update-appcast.sh —— 向 appcast.xml 插入/替换一个发布条目（按 sparkle:shortVersionString 去重，可重复执行）。
# 用法: update-appcast.sh --version V --build B --url U --signature S --length L [--channel C] [--notes-file F]
# 注: Sparkle 用 sparkle:version（对应 CFBundleVersion 构建号）判断更新新旧，
#     必须传单调递增的构建号；sparkle:shortVersionString 仅用于展示。
set -euo pipefail

cd "$(dirname "$0")/.."

APPCAST="appcast.xml"
VERSION="" BUILD="" URL="" SIG="" LEN="" CHANNEL="" NOTES_FILE=""

die() { echo "错误：$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build) BUILD="$2"; shift 2 ;;
        --url) URL="$2"; shift 2 ;;
        --signature) SIG="$2"; shift 2 ;;
        --length) LEN="$2"; shift 2 ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        --notes-file) NOTES_FILE="$2"; shift 2 ;;
        *) die "未知参数：$1" ;;
    esac
done

[[ -n "$VERSION" && -n "$BUILD" && -n "$URL" && -n "$SIG" && -n "$LEN" ]] || die "缺少必需参数（--version/--build/--url/--signature/--length）"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "--build 必须为纯数字构建号（当前：${BUILD}）"
[[ -f "$APPCAST" ]] || die "未找到 $APPCAST"

PUB_DATE="$(date -R)"

# ---------- 组装新 item ----------
ITEM_FILE="$(mktemp)"
{
    echo "    <item>"
    echo "      <title>Version $VERSION</title>"
    echo "      <pubDate>$PUB_DATE</pubDate>"
    if [[ -n "$NOTES_FILE" ]]; then
        echo "      <description><![CDATA["
        cat "$NOTES_FILE"
        echo "]]></description>"
    fi
    if [[ -n "$CHANNEL" ]]; then
        echo "      <sparkle:channel>$CHANNEL</sparkle:channel>"
    fi
    echo "      <enclosure url=\"$URL\""
    echo "                 sparkle:version=\"$BUILD\""
    echo "                 sparkle:shortVersionString=\"$VERSION\""
    echo "                 sparkle:edSignature=\"$SIG\""
    echo "                 length=\"$LEN\""
    echo "                 type=\"application/octet-stream\" />"
    echo "    </item>"
} > "$ITEM_FILE"

# ---------- 移除同版本旧 item 后在 </channel> 前插入 ----------
TMP="$(mktemp)"
awk -v ver="$VERSION" -v itemfile="$ITEM_FILE" '
BEGIN { skip = 0; buf = "" }
/<item>/ { skip = 1; buf = "    <item>\n"; next }
/<\/item>/ && skip {
    buf = buf "    </item>\n"
    # 去重：同版本旧条目丢弃，由新条目替换（匹配 enclosure 的 sparkle:shortVersionString 属性）
    if (buf !~ ("sparkle:shortVersionString=\"" ver "\"")) printf "%s", buf
    skip = 0; buf = ""; next
}
skip { buf = buf $0 "\n"; next }
/<\/channel>/ {
    while ((getline line < itemfile) > 0) print line
    close(itemfile)
}
{ print }
' "$APPCAST" > "$TMP"

mv "$TMP" "$APPCAST"
rm -f "$ITEM_FILE"
echo "appcast.xml 已更新：v${VERSION}${CHANNEL:+（通道 ${CHANNEL}）}"
