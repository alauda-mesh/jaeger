#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# 步骤 2：本地构建 3 个二进制（jaeger / es-rollover / es-index-cleaner）并用 --help 验证。
# 构建方式与 CI（alauda-build-jaeger.yaml）保持一致：
#   SKIP_DEBUG_BINARIES=1 make <target> GIT_CLOSEST_TAG=<上游tag>
# jaeger-ui submodule 恰好位于上游 release tag 时，rebuild-ui 会直接下载预构建 UI 资产（无需 node）。
# 注意：make 的 build-ui 依赖只认 build/index.html 是否存在，workspace 残留的旧版 UI 资产会被
# 直接打进二进制且构建全绿；因此本脚本先强制 make rebuild-ui，构建后再校验内嵌资产一致性。
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

# 与 CI 一致：关闭 Go 的 VCS 版本戳，避免主模块被戳成 v0.0.0 等伪版本、
# 被镜像漏洞扫描误判为远古版本（真实版本由 ldflags 的 GIT_CLOSEST_TAG 注入）
export GOFLAGS="-buildvcs=false"

GOOS=$(go env GOOS)
GOARCH=$(go env GOARCH)
LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sync-upstream-build.XXXXXX")
info "构建日志目录：${LOG_DIR}"
info "jaeger-ui submodule 当前位置：$(git -C jaeger-ui describe --tags --always 2>/dev/null || echo 未知)"

# 强制重建 UI 资产：防止 workspace 残留的旧版 jaeger-ui/packages/jaeger-ui/build/ 被复用
# （CI 曾因 runner 残留把 v2.16.0 UI 打进 v2.20.0 二进制，流水线全绿但镜像 UI 不可用）
info "强制重建 UI 资产（make rebuild-ui，日志：${LOG_DIR}/rebuild-ui.log）..."
if ! make rebuild-ui >"${LOG_DIR}/rebuild-ui.log" 2>&1; then
    echo "---- rebuild-ui 失败日志末尾 40 行 ----"
    tail -n 40 "${LOG_DIR}/rebuild-ui.log"
    echo "---- 日志结束 ----"
    echo "RESULT=BUILD_FAILED"
    exit 2
fi

# 校验 jaeger 二进制内嵌的 UI 资产与 jaeger-ui 构建产物一致（embed 路径 actual/ 下均带 .gz 后缀）。
# 内嵌名单在二进制中无分隔符连续存储，正则字符类不能含 /（否则贪婪匹配跨条目）；
# 按扁平 static 目录设计，若上游资产出现子目录会在此显式失败、提醒调整
verify_ui_assets() {
    local bin="$1"
    grep -aq 'actual/index.html.gz' "$bin" || return 1
    diff <(grep -aoE 'actual/static/[A-Za-z0-9._-]+\.gz' "$bin" | sed 's#^actual/static/##; s#\.gz$##' | sort -u) \
         <(cd jaeger-ui/packages/jaeger-ui/build/static && find . -type f | sed 's#^\./##' | sort)
}

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
        if ! "./${bin}" --help >/dev/null 2>&1; then
            FAILED=1
            SUMMARY+=("${target}: 构建成功但 --help 验证失败（${bin}）")
        elif [ "$target" = "build-jaeger" ] && ! verify_ui_assets "$bin"; then
            FAILED=1
            SUMMARY+=("${target}: 构建成功但内嵌 UI 资产与 jaeger-ui 构建产物不一致（workspace 陈旧残留？）")
        else
            SUMMARY+=("${target}: OK（${bin}，$(du -h "$bin" | cut -f1)）")
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
