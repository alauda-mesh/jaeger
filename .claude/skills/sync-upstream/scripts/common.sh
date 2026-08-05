#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# sync-upstream skill 公共常量与函数（被 scripts/ 下其他脚本 source，不单独执行）

set -euo pipefail

UPSTREAM_URL="https://github.com/jaegertracing/jaeger.git"
# shellcheck disable=SC2034  # 供 source 本文件的脚本使用
FORK_REPO="alauda-mesh/jaeger"

# 所有脚本统一在仓库根目录下执行
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# 状态文件：sync.sh 写入，finish-merge.sh 读取；位于 .git/ 内不会被提交
# shellcheck disable=SC2034  # 供 source 本文件的脚本使用
STATE_FILE="$REPO_ROOT/.git/sync-upstream-state.env"

info() { printf '[sync-upstream] %s\n' "$*"; }
die()  { printf '[sync-upstream] 错误：%s\n' "$*" >&2; exit 1; }

# 校验上游 release tag 格式（vX.Y.Z）
validate_tag() {
    printf '%s' "$1" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        || die "上游 tag 格式无效：$1（应为 vX.Y.Z，如 v2.20.0）"
}

# 校验 ACP 产品版本格式（vX.Y.Z-rN，即集群插件 chart 版本）
validate_acp_version() {
    printf '%s' "$1" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$' \
        || die "ACP 产品版本格式无效：$1（应为 vX.Y.Z-rN，如 v2.2.0-r0）"
}

# 工作区必须干净（含 submodule 指针变动；未跟踪文件不阻塞，merge 冲突时 git 会自行保护），
# 且没有进行中的合并
require_clean_worktree() {
    if [ -n "$(git status --porcelain --untracked-files=no --ignore-submodules=none)" ]; then
        die "工作区不干净，请先提交或清理（git status 查看）"
    fi
    if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
        die "存在进行中的合并（MERGE_HEAD），请先完成或 git merge --abort"
    fi
}

# 确保 upstream remote 存在且指向 jaegertracing/jaeger（缺失时自动添加）
ensure_upstream_remote() {
    local url
    if url=$(git remote get-url upstream 2>/dev/null); then
        if [ "$url" != "$UPSTREAM_URL" ]; then
            die "remote 'upstream' 已存在但指向 ${url}（期望 ${UPSTREAM_URL}），请人工确认后处理"
        fi
    else
        git remote add upstream "$UPSTREAM_URL"
        info "已添加 remote upstream -> ${UPSTREAM_URL}"
    fi
}

# gh 命令重试（应对瞬时网络错误），最多 3 次；成功时输出 stdout
gh_retry() {
    local attempt out
    for attempt in 1 2 3; do
        if out=$(gh "$@" 2>&1); then
            printf '%s\n' "$out"
            return 0
        fi
        if [ "$attempt" -lt 3 ]; then
            sleep 5
        fi
    done
    printf '%s\n' "$out" >&2
    return 1
}

# 合并完成后的收尾：对齐 submodule（idl / jaeger-ui）并输出概览
post_merge_finalize() {
    local tag="$1" target="$2"
    info "对齐 submodule（idl / jaeger-ui）到合并后记录的 commit..."
    git submodule sync --recursive >/dev/null
    git submodule update --init --recursive
    info "submodule 状态："
    git submodule status | sed 's/^/  /'
    # 注意：git submodule status 的描述只认 annotated tag，jaeger-ui 的 release tag 是
    # lightweight，会显示成 v1.10.0-NNN-g... 之类的误导值；以下面 --tags 的结果为准
    info "jaeger-ui 实际位置（describe --tags）：$(git -C jaeger-ui describe --tags --always 2>/dev/null || echo 未知)"
    local merged_count
    merged_count=$(git rev-list --count "origin/${target}..refs/tags/${tag}^{commit}" 2>/dev/null || echo "?")
    info "本次合入的上游提交数（相对 origin/${target}）：${merged_count}"
}
