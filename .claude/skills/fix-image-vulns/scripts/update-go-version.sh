#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0
# 步骤 2b：升级修复 worktree 中 alauda-build-jaeger.yaml 的 go-version（修 go stdlib 漏洞）。
# 用法: update-go-version.sh <X.Y.Z>   例: update-go-version.sh 1.26.7
#   版本格式与 setup-go 一致（不带 go 前缀）。
# 只改值不 commit；go-version 附近的历史注释（pin 原因、CVE 编号）可能过时，
# 脚本会打印出来，由模型判断改写。
# minor 版本须与 go.mod 的 go directive 一致（CI 的 lint-goversion 校验）：
#   同 minor 升 patch → 只改这一处；
#   跨 minor → 脚本仍会改，但输出 CROSS_MINOR 提示，模型必须完成配套修改并在最终报告着重说明。
# 退出码: 0=OK  1=前置失败  2=文件中 go-version 行不唯一（需模型用 Edit 手动改）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  load_state
  [[ $# -eq 1 ]] || die "用法: update-go-version.sh <X.Y.Z>（如 1.26.7，不带 go 前缀）"
  local V="$1"
  [[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "go-version 格式应为 X.Y.Z，收到: $V"

  local WT; WT="$(resolve_worktree)"
  cd "$WT"
  [[ -f "$WORKFLOW_FILE" ]] || die "缺少 $WORKFLOW_FILE"

  local n old
  n="$(grep -cE '^[[:space:]]*go-version:' "$WORKFLOW_FILE" || true)"
  if [[ "$n" -ne 1 ]]; then
    echo "PATTERN_MISMATCH"
    echo "$WORKFLOW_FILE 中 go-version 行有 $n 处（预期恰好 1 处），请用 Edit 手动修改 setup-go 的 go-version 为 $V"
    exit 2
  fi
  old="$(extract_go_version "$WORKFLOW_FILE")"

  if [[ "$old" == "$V" ]]; then
    echo "OK: $WORKFLOW_FILE go-version 已是 $V"
  else
    sed -i -E "s|^([[:space:]]*)go-version:.*$|\1go-version: $V|" "$WORKFLOW_FILE"
    [[ "$(extract_go_version "$WORKFLOW_FILE")" == "$V" ]] \
      || die "$WORKFLOW_FILE go-version 替换未生效，请用 Edit 手动修改"
    echo "OK: $WORKFLOW_FILE go-version: $old → $V"
  fi

  # pin 注释通常记录上次升级的缘由（CVE 编号等），升级后需要模型审阅改写
  if grep -B6 '^[[:space:]]*go-version:' "$WORKFLOW_FILE" | grep -q '#'; then
    echo "NOTICE: go-version 上方注释如下，请审阅并用 Edit 更新为本次升级的缘由（CVE 编号等）："
    grep -n -B6 '^[[:space:]]*go-version:' "$WORKFLOW_FILE" | grep '#' | sed 's/^/    /'
  fi

  # minor 一致性检查（lint-goversion 以 go.mod 的 go directive 为基准校验所有 workflow）
  local gomod_minor new_minor
  gomod_minor="$(sed -n 's/^go \([0-9]*\.[0-9]*\).*/\1/p' go.mod)"
  new_minor="$(cut -d. -f1-2 <<<"$V")"
  echo
  if [[ "$new_minor" == "$gomod_minor" ]]; then
    echo "GO_VERSION_UPDATED（minor $new_minor 与 go.mod 一致，lint-goversion 可通过）"
  else
    echo "CROSS_MINOR: 新版本 minor（$new_minor）≠ go.mod 的 go directive minor（$gomod_minor）。"
    echo "CI 的 lint-goversion（scripts/lint/check-go-version.sh）会失败。模型必须完成配套修改："
    echo "  1. go.mod 的 go directive 升到 $new_minor.0（go mod tidy 验证）"
    echo "  2. 跑 ./scripts/lint/check-go-version.sh 查看所有需对齐的文件"
    echo "     （.golangci.yml 与各社区 workflow；-u 可自动更新，但带 patch 版本的行需手动 Edit）"
    echo "  3. 本地重新构建验证（gomod-bump.sh 或 go build）"
    echo "  4. 最终报告中着重强调 go 大版本变更及原因"
  fi
  git diff --stat -- "$WORKFLOW_FILE" | tail -3
}

main "$@"
