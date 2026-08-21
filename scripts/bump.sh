#!/usr/bin/env bash
# bump.sh —— 版本管理脚本：计算新版本、写入 project.yml、重新生成 Xcode 工程、提交并打 tag。
# 版本单一事实来源为 project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION。
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_YML="project.yml"
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-beta(\.[0-9]+)?)?$'

die() { echo "错误：$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: make bump [patch|minor|major|X.Y.Z] [选项]

版本类型（缺省为 patch）:
  （无）/patch      patch +1；当前为 beta 时定稿（去掉 -beta.N 后缀）
  minor             minor +1，patch 清零
  major             major +1，其余清零
  X.Y.Z             指定版本（可带 v 前缀与 -beta.N 后缀，自动识别）

选项:
  --beta            产出测试版：目标版本追加 -beta.1；
                    当前已是 -beta.N 且未指定类型时递增为 -beta.N+1
  --dump            仅打印当前版本号，不修改任何文件
  --no-commit       写入版本但不自动 git commit
  --no-tag          不创建 git tag（与 --no-commit 同时指定时跳过全部 git 操作）
  --help            显示本帮助

示例:
  make bump                     # 1.0.0 -> v1.0.1
  make bump minor --beta        # 1.0.0 -> v1.1.0-beta.1
  make bump                     # 1.0.1-beta.1 -> v1.0.1（定稿）
  make bump v2.0.0-beta.2       # 直接指定版本
EOF
}

current_version() {
    sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' "$PROJECT_YML" | head -1
}

current_build() {
    sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$PROJECT_YML" | head -1
}

# compare_versions A B -> 打印 1 / 0 / -1（A 相对 B）
compare_versions() {
    local a_base="${1%%-*}" b_base="${2%%-*}"
    local a_suf="${1#"$a_base"}" b_suf="${2#"$b_base"}"
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<< "$a_base"
    IFS=. read -r b1 b2 b3 <<< "$b_base"
    local pairs=("$a1 $b1" "$a2 $b2" "$a3 $b3") p x y
    for p in "${pairs[@]}"; do
        read -r x y <<< "$p"
        if (( x > y )); then echo 1; return; fi
        if (( x < y )); then echo -1; return; fi
    done
    if [[ "$a_suf" == "$b_suf" ]]; then echo 0; return; fi
    # 基础三元组相同：无后缀（正式版）大于带后缀（预发布）
    [[ -z "$a_suf" ]] && { echo 1; return; }
    [[ -z "$b_suf" ]] && { echo -1; return; }
    local an="${a_suf#-beta}" bn="${b_suf#-beta}"
    an="${an#.}"; bn="${bn#.}"
    [[ -z "$an" ]] && an=0
    [[ -z "$bn" ]] && bn=0
    if (( an > bn )); then echo 1; else echo -1; fi
}

# ---------- 参数解析 ----------
LEVEL="" EXPLICIT="" BETA=0 DUMP=0 NO_COMMIT=0 NO_TAG=0

for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        --beta) BETA=1 ;;
        --dump) DUMP=1 ;;
        --no-commit) NO_COMMIT=1 ;;
        --no-tag) NO_TAG=1 ;;
        patch|minor|major)
            [[ -n "$LEVEL" || -n "$EXPLICIT" ]] && die "版本类型只能指定一次（已有：${LEVEL:-$EXPLICIT}）"
            LEVEL="$arg"
            ;;
        --*) die "未知选项：${arg}（--help 查看用法）" ;;
        *)
            [[ -n "$EXPLICIT" || -n "$LEVEL" ]] && die "版本类型只能指定一次（已有：${LEVEL:-$EXPLICIT}）"
            EXPLICIT="${arg#[vV]}"
            ;;
    esac
done

CUR="$(current_version)"
[[ -n "$CUR" ]] || die "无法从 $PROJECT_YML 读取 MARKETING_VERSION"

if (( DUMP )); then
    echo "$CUR"
    exit 0
fi

# ---------- 计算目标版本 ----------
NEW=""
if [[ -n "$EXPLICIT" ]]; then
    [[ "$EXPLICIT" =~ $VERSION_RE ]] || die "无效版本号：${EXPLICIT}（期望格式 X.Y.Z 或 X.Y.Z-beta.N）"
    NEW="$EXPLICIT"
    if (( BETA )) && [[ "$NEW" != *-* ]]; then NEW="$NEW-beta.1"; fi
else
    BASE="${CUR%%-*}"
    IS_BETA=0; [[ "$CUR" == *-* ]] && IS_BETA=1
    IFS=. read -r MA MI PA <<< "$BASE"
    L="${LEVEL:-patch}"
    if (( IS_BETA )) && [[ "$L" == "patch" ]]; then
        if (( BETA )); then
            # 当前已是 beta：递增 beta 序号
            N="${CUR##*-beta}"; N="${N#.}"; [[ -z "$N" ]] && N=0
            NEW="$BASE-beta.$(( N + 1 ))"
        else
            # 定稿：去掉 beta 后缀
            NEW="$BASE"
        fi
    else
        case "$L" in
            patch) NEW="$MA.$MI.$(( PA + 1 ))" ;;
            minor) NEW="$MA.$(( MI + 1 )).0" ;;
            major) NEW="$(( MA + 1 )).0.0" ;;
        esac
        (( BETA )) && NEW="$NEW-beta.1"
    fi
fi

# ---------- 防呆 ----------
CMP="$(compare_versions "$NEW" "$CUR")"
(( CMP > 0 )) || die "目标版本 ${NEW} 不高于当前版本 ${CUR}（拒绝降级/重复）"

if (( NO_COMMIT )) && (( ! NO_TAG )); then
    die "--no-commit 时必须同时指定 --no-tag（tag 需指向包含版本变更的提交）"
fi

DO_GIT=1
if (( NO_COMMIT )) && (( NO_TAG )); then DO_GIT=0; fi

if (( DO_GIT )); then
    [[ -z "$(git status --porcelain)" ]] || die "工作区有未提交改动，请先 commit 或 stash 后再执行"
    git rev-parse "v$NEW" >/dev/null 2>&1 && die "tag v$NEW 已存在"
fi

# ---------- 写入 ----------
NEW_BUILD=$(( $(current_build) + 1 ))
sed -E -i '' "s|(MARKETING_VERSION: \").*(\")|\1$NEW\2|" "$PROJECT_YML"
sed -E -i '' "s|(CURRENT_PROJECT_VERSION: \").*(\")|\1$NEW_BUILD\2|" "$PROJECT_YML"

echo "${CUR} -> ${NEW}（build ${NEW_BUILD}）"

# ---------- 同步重新生成 Xcode 工程 ----------
# .xcodeproj 为 xcodegen 生成的本地产物（gitignore）；bump 后若不重新生成，
# 本地直接用 Xcode 构建会沿用 pbxproj 里的旧版本号。
if command -v xcodegen >/dev/null 2>&1; then
    if xcodegen generate --quiet; then
        echo "已重新生成 Xcode 工程（版本号已同步）"
    else
        echo "警告：xcodegen generate 失败，构建前请手动执行 make generate" >&2
    fi
else
    echo "提示：未检测到 xcodegen，构建前请先 make generate，否则本地构建仍为旧版本号" >&2
fi

# ---------- 提交与打 tag ----------
if (( ! NO_COMMIT )); then
    git add "$PROJECT_YML"
    git commit -m "chore(release): v$NEW"
fi
if (( ! NO_TAG )); then
    git tag "v$NEW"
    echo "已创建 tag: v$NEW"
    echo "提示：git push origin main --tags 后 GitHub Actions 将自动发布"
fi
