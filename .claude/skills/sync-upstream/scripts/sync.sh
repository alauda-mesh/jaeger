#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# 步骤 1：同步上游 tag —— 基于目标分支创建 sync/<tag> 分支并 merge 上游 tag，
# 成功后对齐 idl / jaeger-ui submodule。
#
# 用法：sync.sh <上游tag> <目标分支>    例：sync.sh v2.20.0 main
# 退出码：0=MERGED 或 UP_TO_DATE；2=CONFLICT（解决冲突后运行 finish-merge.sh）；1=前置条件错误

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[ $# -eq 2 ] || die "用法：sync.sh <上游tag> <目标分支>（如 v2.20.0 main）"
TAG="$1"
TARGET="$2"
validate_tag "$TAG"
BRANCH="sync/${TAG}"

require_clean_worktree
ensure_upstream_remote

info "fetch origin/${TARGET} 与上游 tag ${TAG}..."
git fetch origin "$TARGET" || die "fetch origin/${TARGET} 失败（分支不存在或网络问题）"
# 只拉取指定 tag 及其历史；若本地已有同名但指向不同 commit 的 tag，git 会拒绝并报错
git fetch --no-tags upstream "refs/tags/${TAG}:refs/tags/${TAG}" \
    || die "从上游获取 tag ${TAG} 失败（tag 不存在或网络问题）"

TAG_COMMIT=$(git rev-parse "refs/tags/${TAG}^{commit}")

if git merge-base --is-ancestor "$TAG_COMMIT" "origin/${TARGET}"; then
    info "origin/${TARGET} 已包含 ${TAG}（${TAG_COMMIT:0:12}），无需同步"
    echo "RESULT=UP_TO_DATE"
    exit 0
fi

if git rev-parse -q --verify "refs/heads/${BRANCH}" >/dev/null; then
    die "本地分支 ${BRANCH} 已存在；确认无用后可 git branch -D ${BRANCH} 再重跑"
fi

git checkout -b "$BRANCH" "origin/${TARGET}"
printf 'TAG=%s\nTARGET=%s\nBRANCH=%s\n' "$TAG" "$TARGET" "$BRANCH" > "$STATE_FILE"

info "merge ${TAG} 到 ${BRANCH}..."
# merge 输出（含数千行 diffstat）重定向到日志文件，避免刷屏；--signoff 满足上游 DCO 惯例
MERGE_LOG=$(mktemp "${TMPDIR:-/tmp}/sync-upstream-merge.XXXXXX.log")
if ! git merge --no-ff --no-edit --signoff \
        -m "chore: merge upstream ${TAG} into ${TARGET}" "refs/tags/${TAG}" \
        >"$MERGE_LOG" 2>&1; then
    if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
        echo
        info "合并出现冲突（完整 merge 输出：${MERGE_LOG}），冲突文件："
        git diff --name-only --diff-filter=U | sed 's/^/  /'
        info "请按 SKILL.md 的冲突解决原则逐个处理，git add 后运行 scripts/finish-merge.sh"
        echo "RESULT=CONFLICT"
        exit 2
    fi
    tail -n 50 "$MERGE_LOG"
    die "merge 失败且无 MERGE_HEAD，请查看上方 git 输出定位原因"
fi
info "merge 完成：$(git show --shortstat --format='' HEAD | tail -n 1 | sed 's/^ *//')（完整输出：${MERGE_LOG}）"

post_merge_finalize "$TAG" "$TARGET"
echo "RESULT=MERGED"
echo "NEXT=运行 scripts/build.sh ${TAG} 做本地构建验证"
