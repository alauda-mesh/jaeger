#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# 步骤 1 的冲突收尾：确认冲突已全部解决后完成合并 commit（禁止 amend），
# 并对齐 idl / jaeger-ui submodule。在 sync.sh 返回 CONFLICT 并人工解决冲突后运行。
#
# 用法：finish-merge.sh（无参数，上下文取自 sync.sh 写入的状态文件）
# 退出码：0=MERGED；1=仍有未解决冲突或前置条件错误

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[ -f "$STATE_FILE" ] || die "找不到状态文件 ${STATE_FILE}，请先运行 sync.sh"
# shellcheck source=/dev/null
source "$STATE_FILE"   # 提供 TAG / TARGET / BRANCH
TAG="${TAG:?状态文件缺少 TAG}"
TARGET="${TARGET:?状态文件缺少 TARGET}"
BRANCH="${BRANCH:?状态文件缺少 BRANCH}"

CURRENT=$(git rev-parse --abbrev-ref HEAD)
[ "$CURRENT" = "$BRANCH" ] || die "当前分支为 ${CURRENT}，应在 ${BRANCH} 上运行"

UNMERGED=$(git diff --name-only --diff-filter=U)
if [ -n "$UNMERGED" ]; then
    info "仍有未解决的冲突文件："
    printf '%s\n' "$UNMERGED" | sed 's/^/  /'
    die "全部解决并 git add 后再重跑 finish-merge.sh"
fi

if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    git commit --no-edit
    info "合并 commit 已创建（新 commit，未使用 amend）"
else
    info "无进行中的合并（可能已提交过合并 commit），继续收尾"
fi

post_merge_finalize "$TAG" "$TARGET"
echo "RESULT=MERGED"
echo "NEXT=运行 scripts/build.sh ${TAG} 做本地构建验证"
