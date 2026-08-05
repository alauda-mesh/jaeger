#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0
# fix-image-vulns 公共函数与状态管理。
# 状态目录 .tmp/fix-image-vulns/（.tmp/ 在 .gitignore 内）：
#   state.env          键值状态（ROUND、BASE_BRANCH、FIX_BRANCH、PR_NUMBER 等），脚本间传递
#   images-roundN.tsv  第 N 轮待扫描镜像（轮次/来源/类别/镜像地址）
#   scans/roundN/      扫描原始 JSON 与分类 TSV
#   worktree/          修复 worktree（基于当前分支，不打扰主工作区检出）
set -euo pipefail

REPO="${FIX_REPO:-alauda-mesh/jaeger}"
WORKFLOW_NAME="Alauda Build Jaeger"
WORKFLOW_FILE=".github/workflows/alauda-build-jaeger.yaml"
# 内网扫描服务：主备两个地址（备用地址的服务容易故障），scan-images.sh 探测选用
SCAN_API_PRIMARY="${SCAN_API_PRIMARY:-http://192.168.141.42:8888}"
SCAN_API_BACKUP="${SCAN_API_BACKUP:-http://192.168.25.100:8888}"
# 修复范围：三个 go 镜像共用仓库根 go.mod，漏洞统一分析、一次修复
FIX_REPOS="jaeger jaeger-es-rollover jaeger-es-index-cleaner"
# 只扫不修：oauth2-proxy 为第三方镜像，漏洞如实报告
REPORT_REPOS="oauth2-proxy"

die()  { echo "错误: $*" >&2; exit 1; }
warn() { echo "警告: $*" >&2; }
info() { echo "==> $*" >&2; }

STATE_DIR_REL=".tmp/fix-image-vulns"

repo_root() {
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
  # worktree 中执行时回到主仓库根（状态目录只放主仓库）。
  # --git-common-dir 在主仓库根返回相对的 ".git"，必须转成绝对路径再比较，
  # 否则主仓库会被误判、ROOT 退化成 "."
  local common; common="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
  [[ "$common" != "$ROOT/.git" ]] && ROOT="$(dirname "$common")"
  [[ -f "$ROOT/$WORKFLOW_FILE" && -d "$ROOT/alauda" ]] \
    || die "当前仓库不是 alauda-mesh/jaeger 仓库: $ROOT"
  cd "$ROOT"
  STATE_DIR="$ROOT/$STATE_DIR_REL"
  STATE_FILE="$STATE_DIR/state.env"
  mkdir -p "$STATE_DIR"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "状态文件不存在: $STATE_FILE（先执行 resolve-input.sh）"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

set_state() { # set_state KEY VALUE
  touch "$STATE_FILE"
  grep -v "^${1}=" "$STATE_FILE" >"$STATE_FILE.tmp" || true
  echo "${1}=\"${2}\"" >>"$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

require_gh() {
  command -v gh >/dev/null 2>&1 || die "找不到 gh CLI"
  gh auth status >/dev/null 2>&1 || die "gh 未认证。请提示用户在会话中执行: ! gh auth login"
}

# push/建 PR 前的安全守卫：origin 不是 alauda-mesh/jaeger 时拒绝外发（禁止推社区上游）
origin_is_alauda() {
  local url; url="$(git remote get-url origin 2>/dev/null || true)"
  [[ "$url" =~ github\.com[:/]${REPO}(\.git)?$ ]]
}

# 镜像地址 → 安全文件名
img_slug() { tr '/:@' '___' <<<"$1"; }

# 镜像地址 → 短仓库名（build-harbor.alauda.cn/asm/jaeger:tag → jaeger）
img_repo() { local p="${1%%:*}"; echo "${p##*/}"; }

# 短仓库名 → 处理类别：FIX（修复）/ REPORT（只扫不修）/ IGNORE（不纳入）
repo_category() {
  local r="$1"
  if grep -qw "$r" <<<"$FIX_REPOS"; then echo FIX
  elif grep -qw "$r" <<<"$REPORT_REPOS"; then echo REPORT
  else echo IGNORE; fi
}

# 修复 worktree 目录（单分支模型，只有一个）
worktree_dir() { echo "$STATE_DIR/worktree"; }

resolve_worktree() {
  local wt; wt="$(worktree_dir)"
  [[ -d "$wt" && -f "$wt/go.mod" ]] || die "修复 worktree 不存在: $wt（先执行 create-fix-branch.sh）"
  echo "$wt"
}

# 从 workflow 文件中提取 setup-go 的 go-version（可能带引号）
extract_go_version() { # extract_go_version <workflow文件>
  sed -n 's/^[[:space:]]*go-version:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*$/\1/p' "$1" | head -1
}

# 从 run 的 "Output images" job 日志提取 BUILD_IMAGES JSON 数组（提取不到输出空，由调用方处理）
extract_build_images() { # extract_build_images <run_id>
  local job_id
  job_id="$(gh run view "$1" --repo "$REPO" --json jobs \
    --jq '.jobs[] | select(.name == "Output images") | .databaseId' 2>/dev/null | head -1)"
  [[ -n "$job_id" ]] || return 0
  gh run view "$1" --repo "$REPO" --job "$job_id" --log 2>/dev/null \
    | tr -d '\r' | sed -n 's/.*BUILD_IMAGES=\(\[.*\]\)$/\1/p' | head -1
}
