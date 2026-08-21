#!/usr/bin/env bash
# release-notes.sh —— 基于 Conventional Commits 生成分类更新日志。
# 用法: release-notes.sh [--html|--md] [PREV_TAG] [CUR_REF]
#   PREV_TAG 省略时输出全部提交历史；CUR_REF 默认 HEAD。
# 分类：feat→新增功能 / fix→问题修复 / perf→性能优化 / 其余→其他；跳过 chore(release) 提交。
set -euo pipefail

MODE="md"
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --html) MODE="html" ;;
        --md) MODE="md" ;;
        *) ARGS+=("$arg") ;;
    esac
done

PREV=""; CUR="HEAD"
if [[ ${#ARGS[@]} -ge 1 ]]; then PREV="${ARGS[0]}"; fi
if [[ ${#ARGS[@]} -ge 2 ]]; then CUR="${ARGS[1]}"; fi

RANGE="${PREV:+$PREV..}$CUR"

git log "$RANGE" --pretty=%s | awk -v mode="$MODE" '
function esc(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    return s
}
function flush(title, arr, n,   i) {
    if (n == 0) return
    if (mode == "html") {
        print "<p><b>" title "</b></p>"
        print "<ul>"
        for (i = 1; i <= n; i++) print "<li>" esc(arr[i]) "</li>"
        print "</ul>"
    } else {
        print "## " title
        print ""
        for (i = 1; i <= n; i++) print "- " arr[i]
        print ""
    }
}
/^chore\(release\)/ { next }
{
    msg = $0
    type = msg
    sub(/[\(!:].*/, "", type)
    # 去除 type(scope): / type!: 前缀，保留描述部分
    sub(/^[a-zA-Z]+(\([^)]*\))?!?: */, "", msg)
    if (type == "feat") feats[++nf] = msg
    else if (type == "fix") fixes[++nx] = msg
    else if (type == "perf") perfs[++np] = msg
    else others[++no] = msg
}
END {
    if (nf + nx + np + no == 0) {
        if (mode == "html") print "<p>本次发布暂无记录变更。</p>"
        else print "本次发布暂无记录变更。"
        exit
    }
    flush("✨ 新增功能", feats, nf)
    flush("🐛 问题修复", fixes, nx)
    flush("⚡️ 性能优化", perfs, np)
    flush("🔧 其他", others, no)
}
'
