#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# ============================================================================
# 说明：
#   使用 Jaeger 发行版版本号（即镜像 tag，如 2.16.0-r2）一次性更新以下位置：
#     - Chart.yaml           顶层 `version:`（chart 版本，带 v 前缀）
#     - Chart.yaml           顶层 `appVersion:`（Jaeger 发行版版本）
#     - module-plugin.yaml   `spec.appReleases[0].chartVersions[0].version`
#     - values.yaml          3 个 Jaeger 镜像的 tag（以行尾 "# jaeger-tag" 标记定位）
#
#   兼容 GNU sed（Linux）和 BSD sed（macOS）。
#
# 用法：
#   ./hack/update-version.sh <JAEGER_TAG>
#
# 示例：
#   ./hack/update-version.sh 2.16.0-r2
#   ./hack/update-version.sh 2.16.0-pr.5.12
# ============================================================================

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "错误：参数数量不正确。" >&2
    echo "用法：$0 <JAEGER_TAG>（如 2.16.0-r2，不带 v 前缀）" >&2
    exit 1
fi

JAEGER_TAG="$1"
# chart 版本统一带 v 前缀（若入参已带 v 则不重复添加）
CHART_VERSION="v${JAEGER_TAG#v}"

# 定位 chart 根目录（本脚本 hack/ 目录的上级目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHART_FILE="$CHART_ROOT/Chart.yaml"
MODULE_PLUGIN_FILE="$CHART_ROOT/module-plugin.yaml"
VALUES_FILE="$CHART_ROOT/values.yaml"

for f in "$CHART_FILE" "$MODULE_PLUGIN_FILE" "$VALUES_FILE"; do
    if [ ! -f "$f" ]; then
        echo "错误：文件不存在：$f" >&2
        exit 1
    fi
done

# 跨平台 in-place sed：macOS 的 BSD sed 需要显式的空备份后缀
sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# 转义替换串中的特殊字符（`/`、`&`、`\`），版本号按字面量处理
escape() {
    printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

ESCAPED_CHART_VERSION=$(escape "$CHART_VERSION")
ESCAPED_JAEGER_TAG=$(escape "$JAEGER_TAG")

# Chart.yaml：顶层 `version:` 与 `appVersion:`（无前导空格）
sed_inplace -E "s/^version: .*/version: ${ESCAPED_CHART_VERSION}/" "$CHART_FILE"
sed_inplace -E "s/^appVersion: .*/appVersion: \"${ESCAPED_JAEGER_TAG}\"/" "$CHART_FILE"

# module-plugin.yaml：chartVersions[0] 下的 `version:`（6 空格缩进）
sed_inplace -E "s/^      version: .*/      version: ${ESCAPED_CHART_VERSION}/" "$MODULE_PLUGIN_FILE"

# values.yaml：所有以 "# jaeger-tag" 标记结尾的 tag 行（3 个 Jaeger 镜像共用同一版本）
sed_inplace -E "s/^([[:space:]]*)tag: .* # jaeger-tag$/\1tag: \"${ESCAPED_JAEGER_TAG}\" # jaeger-tag/" "$VALUES_FILE"

echo "已更新 chart 版本为：${CHART_VERSION}（Jaeger 镜像 tag：${JAEGER_TAG}）"
echo "  - ${CHART_FILE}"
echo "  - ${MODULE_PLUGIN_FILE}"
echo "  - ${VALUES_FILE}"
