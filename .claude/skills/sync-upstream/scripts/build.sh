#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# 步骤 2：本地构建 3 个二进制（jaeger / es-rollover / es-index-cleaner）并用 --help 验证。
# 构建方式与 CI（alauda-build-jaeger.yaml）保持一致：
#   SKIP_DEBUG_BINARIES=1 make <target> GIT_CLOSEST_TAG=<上游tag>
# jaeger-ui submodule 恰好位于上游 release tag 时，rebuild-ui 会直接下载预构建 UI 资产（无需 node）。
#
# 用法：build.sh <上游tag>    例：build.sh v2.20.0
# 退出码：0=BUILD_OK；2=BUILD_FAILED（读日志分析修复后重跑）；1=参数错误

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[ $# -eq 1 ] || die "用法：build.sh <上游tag>（如 v2.20.0）"
TAG="$1"
validate_tag "$TAG"

GOOS=$(go env GOOS)
GOARCH=$(go env GOARCH)
LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sync-upstream-build.XXXXXX")
info "构建日志目录：${LOG_DIR}"
info "jaeger-ui submodule 当前位置：$(git -C jaeger-ui describe --tags --always 2>/dev/null || echo 未知)"

# target -> 构建产物路径
declare -A BIN_PATH=(
    [build-jaeger]="cmd/jaeger/jaeger-${GOOS}-${GOARCH}"
    [build-es-rollover]="cmd/es-rollover/es-rollover-${GOOS}-${GOARCH}"
    [build-es-index-cleaner]="cmd/es-index-cleaner/es-index-cleaner-${GOOS}-${GOARCH}"
)

FAILED=0
SUMMARY=()
for target in build-jaeger build-es-rollover build-es-index-cleaner; do
    info "make ${target}（日志：${LOG_DIR}/${target}.log）..."
    if SKIP_DEBUG_BINARIES=1 make "$target" GIT_CLOSEST_TAG="$TAG" >"${LOG_DIR}/${target}.log" 2>&1; then
        bin="${BIN_PATH[$target]}"
        if "./${bin}" --help >/dev/null 2>&1; then
            SUMMARY+=("${target}: OK（${bin}，$(du -h "$bin" | cut -f1)）")
        else
            FAILED=1
            SUMMARY+=("${target}: 构建成功但 --help 验证失败（${bin}）")
        fi
    else
        FAILED=1
        SUMMARY+=("${target}: 构建失败（完整日志：${LOG_DIR}/${target}.log）")
        echo "---- ${target} 失败日志末尾 60 行 ----"
        tail -n 60 "${LOG_DIR}/${target}.log"
        echo "---- 日志结束 ----"
    fi
done

echo
info "构建结果汇总："
printf '  %s\n' "${SUMMARY[@]}"

if [ "$FAILED" -ne 0 ]; then
    echo "RESULT=BUILD_FAILED"
    exit 2
fi
echo "RESULT=BUILD_OK"
echo "NEXT=运行 scripts/update-chart.sh ${TAG} <ACP产品版本> 更新集群插件版本"
