#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0
# 步骤 2a：基于当前分支（resolve 时记录的 BASE_BRANCH）创建修复分支。
# 用法: create-fix-branch.sh
# 用 git worktree（.tmp/fix-image-vulns/worktree），不打扰主工作区当前检出。
# 分支命名: fix/cve-<UTC日期>
# 幂等：worktree 已在对应修复分支上时直接复用（回归轮追加 commit 用）。
# 输出: WORKTREE= / BRANCH= / BASE=
# 退出码: 0=OK  1=失败（含：本地基线分支领先 origin，需人工确认，防止把未 push 的
#         commit 混入修复 PR）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  load_state
  [[ -n "${BASE_BRANCH:-}" ]] || die "状态中没有 BASE_BRANCH（先执行 resolve-input.sh）"

  local FIX_BRANCH; FIX_BRANCH="fix/cve-$(date -u +%Y%m%d)"
  local WT; WT="$(worktree_dir)"

  # ---------- 基线分支与 origin 的领先/落后检查 ----------
  if git fetch -q origin "refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" 2>/dev/null; then
    local ahead behind
    ahead="$(git rev-list --count "refs/remotes/origin/$BASE_BRANCH..refs/heads/$BASE_BRANCH")"
    behind="$(git rev-list --count "refs/heads/$BASE_BRANCH..refs/remotes/origin/$BASE_BRANCH")"
    [[ "$ahead" -gt 0 ]] && die "本地分支 $BASE_BRANCH 领先 origin $ahead 个 commit。
基于它建修复分支会把这些未 push 的 commit 一并带进 PR。请先 push 或与用户确认后再重跑"
    [[ "$behind" -gt 0 ]] && warn "本地分支 $BASE_BRANCH 落后 origin $behind 个 commit，修复将基于本地旧基线（如需最新代码请先 git pull 再重跑 resolve-input.sh）"
  else
    warn "fetch origin/$BASE_BRANCH 失败，跳过领先/落后检查"
  fi

  # ---------- worktree 幂等处理 ----------
  if [[ -e "$WT" ]]; then
    local cur
    cur="$(git -C "$WT" branch --show-current 2>/dev/null || true)"
    if [[ "$cur" == "$FIX_BRANCH" ]]; then
      info "worktree 已在分支 $FIX_BRANCH 上，直接复用"
    elif [[ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ]]; then
      info "移除残留的干净 worktree（原分支 ${cur:-未知}）"
      git worktree remove --force "$WT"
    else
      die "$WT 已存在且有未提交改动（分支 ${cur:-未知}），请人工确认后再处理"
    fi
  fi

  if [[ ! -e "$WT" ]]; then
    if git rev-parse --verify --quiet "refs/heads/$FIX_BRANCH" >/dev/null; then
      # 同日重跑：本地已有该修复分支（如上次中断），挂载 worktree 继续用
      warn "本地已存在分支 $FIX_BRANCH，直接挂载（其提交历史保留）"
      git worktree add -q "$WT" "$FIX_BRANCH"
    else
      git worktree add -q "$WT" -b "$FIX_BRANCH" "refs/heads/$BASE_BRANCH"
    fi
  fi

  set_state FIX_BRANCH "$FIX_BRANCH"

  echo
  echo "BRANCH_READY"
  echo "WORKTREE=$WT"
  echo "BRANCH=$FIX_BRANCH"
  echo "BASE=$BASE_BRANCH（$(git rev-parse --short "refs/heads/$BASE_BRANCH")）"
  echo "下一步: 按修复目标执行 update-go-version.sh / gomod-bump.sh"
}

main "$@"
