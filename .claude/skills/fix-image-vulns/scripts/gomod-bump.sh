#!/usr/bin/env bash
# 步骤 2c：在修复 worktree 中升级 go.mod 依赖并做本地构建验证。
# 用法: gomod-bump.sh <module@vX.Y.Z> [module@vX.Y.Z ...]
#       gomod-bump.sh --build-only        # 只做构建验证（如仅改了 go-version 时）
#   例: gomod-bump.sh golang.org/x/net@v0.60.0
# 版本号必须带 v 前缀（扫描给的修复候选没有 v，拼参数时要加上）。
# 构建验证编译三个修复镜像的 go 二进制入口（cmd/jaeger、cmd/es-rollover、
# cmd/es-index-cleaner 及其子包），会连带编译依赖的全部包，足以验证升级未破坏构建；
# UI 资产缺失时 embed 走 placeholder 兜底，纯 go build 不需要 jaeger-ui submodule。
# 退出码: 0=构建验证通过（RESULT: BUILD_OK） 非0=某一步失败（保留现场供分析）
# 注意: go get 下载依赖 + 编译可能要几分钟，Bash timeout 设 600000；
#       冷缓存首跑可能超时，建议 run_in_background: true。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  load_state
  [[ $# -ge 1 ]] || die "用法: gomod-bump.sh <module@vX.Y.Z ...> | --build-only"
  local WT; WT="$(resolve_worktree)"
  command -v go >/dev/null 2>&1 || die "找不到 go 工具链"

  cd "$WT"
  # go.mod / 新依赖要求的 go 版本可能高于本机默认，auto 允许按需获取工具链；
  # GOPROXY 与 CI（alauda-build-jaeger.yaml 的 env）保持一致
  export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
  export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

  local BUILD_ONLY=0
  [[ "$1" == "--build-only" ]] && BUILD_ONLY=1

  local before_go; before_go="$(sed -n 's/^go //p' go.mod)"
  if [[ "$BUILD_ONLY" -eq 0 ]]; then
    info "go get $*"
    go get "$@"
    info "go mod tidy"
    go mod tidy
  fi
  info "构建验证: go build ./cmd/jaeger/... ./cmd/es-rollover/... ./cmd/es-index-cleaner/...（首次需下载依赖，可能几分钟）"
  go build ./cmd/jaeger/... ./cmd/es-rollover/... ./cmd/es-index-cleaner/...

  if [[ "$BUILD_ONLY" -eq 0 ]]; then
    echo
    echo "实际落位版本（依赖间约束可能使其高于请求版本，属正常）:"
    local spec mod
    for spec in "$@"; do
      mod="${spec%@*}"
      echo "  $(go list -m "$mod" 2>/dev/null || echo "$mod （已不在依赖图中）")"
    done
    local after_go; after_go="$(sed -n 's/^go //p' go.mod)"
    [[ "$before_go" != "$after_go" ]] \
      && warn "go.mod 的 go directive 被连带提升: $before_go → $after_go（workflow 的 go-version 须 ≥ 该版本且 minor 一致，必要时执行 update-go-version.sh，并在 PR 正文中说明）"
    echo
    echo "变更文件（提交前用 git diff go.mod 审查连带升级面）:"
    git status --short
  fi
  echo "RESULT: BUILD_OK"
}

main "$@"
