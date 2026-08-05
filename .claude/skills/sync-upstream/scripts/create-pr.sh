#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# 步骤 4：push 同步分支与上游 tag，并在 alauda-mesh/jaeger 上创建 PR（已有 PR 时幂等复用）。
# 注意：本仓库存在 upstream remote，gh 可能把默认仓库解析成上游，
# 因此所有 gh 命令都显式 --repo alauda-mesh/jaeger，严禁向上游建 PR。
#
# 用法：create-pr.sh <上游tag> <目标分支> <PR正文文件>
# 退出码：0=成功（输出 PR_NUMBER= 与 PR_URL=）；1=前置条件或执行错误

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[ $# -eq 3 ] || die "用法：create-pr.sh <上游tag> <目标分支> <PR正文文件>"
TAG="$1"
TARGET="$2"
BODY_FILE="$3"
validate_tag "$TAG"
[ -f "$BODY_FILE" ] || die "PR 正文文件不存在：${BODY_FILE}"
BRANCH="sync/${TAG}"

command -v gh >/dev/null 2>&1 || die "未找到 gh 命令，请先安装 GitHub CLI"
gh auth status >/dev/null 2>&1 || die "gh 未认证，请提示用户执行：! gh auth login"

CURRENT=$(git rev-parse --abbrev-ref HEAD)
[ "$CURRENT" = "$BRANCH" ] || die "当前分支为 ${CURRENT}，应在 ${BRANCH} 上运行"
if [ -n "$(git status --porcelain)" ]; then
    die "工作区有未提交改动，先提交（新 commit，禁止 amend）再创建 PR"
fi

info "push 同步分支 ${BRANCH} 到 origin（fork）..."
git push origin "$BRANCH"

# fork 约定携带上游 release tag（git describe 版本推导依赖）；重复推送是幂等 no-op。
# fork 的构建 workflow 只被 plugin-v*-r* tag 触发，推上游版本 tag 不会触发任何构建。
info "push 上游 tag ${TAG} 到 origin（fork）..."
git push origin "refs/tags/${TAG}"

PR_NUMBER=$(gh_retry pr list --repo "$FORK_REPO" --head "$BRANCH" --base "$TARGET" \
    --state open --json number --jq '.[0].number // empty')
if [ -n "$PR_NUMBER" ]; then
    info "分支已有打开的 PR #${PR_NUMBER}，幂等复用"
else
    info "创建 PR（--repo ${FORK_REPO}）..."
    gh_retry pr create --repo "$FORK_REPO" --base "$TARGET" --head "$BRANCH" \
        --title "chore: sync upstream ${TAG}" --body-file "$BODY_FILE" >/dev/null
    PR_NUMBER=$(gh_retry pr list --repo "$FORK_REPO" --head "$BRANCH" --base "$TARGET" \
        --state open --json number --jq '.[0].number // empty')
    [ -n "$PR_NUMBER" ] || die "PR 创建后未能查询到编号，请用 gh pr list --repo ${FORK_REPO} 排查"
fi
PR_URL=$(gh_retry pr view "$PR_NUMBER" --repo "$FORK_REPO" --json url --jq '.url')

echo "PR_NUMBER=${PR_NUMBER}"
echo "PR_URL=${PR_URL}"
echo "NEXT=后台运行 scripts/watch-pipeline.sh ${PR_NUMBER} 监控流水线"
