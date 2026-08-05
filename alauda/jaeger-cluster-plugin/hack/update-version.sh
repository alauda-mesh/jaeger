#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# ============================================================================
# 说明：
#   使用集群插件 chart 版本与上游 Jaeger 版本一次性更新以下位置：
#     - Chart.yaml           顶层 `version:`（chart 版本，带 v 前缀）
#     - Chart.yaml           顶层 `appVersion:`（上游 Jaeger 版本）
#     - module-plugin.yaml   `spec.appReleases[0].chartVersions[0].version`
#     - values.yaml          3 个 Jaeger 镜像的 tag（以行尾 "# jaeger-tag" 标记定位），
#                            tag 拼接为 <Jaeger 版本>-<chart 版本去 v 前缀>
#
#   oauth2-proxy 镜像版本独立维护（values.yaml 行尾 "# oauth2-proxy-tag" 标记），
#   本脚本不做修改。
#
#   兼容 GNU sed（Linux）和 BSD sed（macOS）。
#
# 用法：
#   ./hack/update-version.sh <CHART_VERSION> <JAEGER_VERSION>
#
# 示例：
#   ./hack/update-version.sh v2.1.0-r0 2.16.0
#   ./hack/update-version.sh v2.1.0-rc.1 2.16.0
#   ./hack/update-version.sh v2.1.0-pr.6.123 2.16.0
# ============================================================================

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "错误：参数数量不正确。" >&2
    echo "用法：$0 <CHART_VERSION> <JAEGER_VERSION>（如 v2.1.0-r0 2.16.0）" >&2
    exit 1
fi

# chart 版本统一带 v 前缀（若入参已带 v 则不重复添加）
CHART_VERSION="v${1#v}"
# Jaeger 版本为纯上游语义版本（若入参带 v 前缀则去掉）
JAEGER_VERSION="${2#v}"

# 校验版本格式，防止误传旧式单参数（如 2.16.0-r2）或缺少必需的版本后缀
if ! printf '%s' "$CHART_VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+-(r[0-9]+|rc\.[0-9]+|pr\.[0-9]+\.[0-9]+)$'; then
    echo "错误：chart 版本格式无效：${CHART_VERSION}（应为 vX.Y.Z-rN、vX.Y.Z-rc.N 或 vX.Y.Z-pr.<PR号>.<运行号>）" >&2
    exit 1
fi
if ! printf '%s' "$JAEGER_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "错误：Jaeger 版本格式无效：${JAEGER_VERSION}（应为上游语义版本，如 2.16.0）" >&2
    exit 1
fi

# Jaeger 镜像 tag：同时携带 Jaeger 版本与插件版本，与 chart 一一对应
IMAGE_TAG="${JAEGER_VERSION}-${CHART_VERSION#v}"

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
ESCAPED_JAEGER_VERSION=$(escape "$JAEGER_VERSION")
ESCAPED_IMAGE_TAG=$(escape "$IMAGE_TAG")

# Chart.yaml：顶层 `version:` 与 `appVersion:`（无前导空格）
sed_inplace -E "s/^version: .*/version: ${ESCAPED_CHART_VERSION}/" "$CHART_FILE"
sed_inplace -E "s/^appVersion: .*/appVersion: \"${ESCAPED_JAEGER_VERSION}\"/" "$CHART_FILE"

# module-plugin.yaml：chartVersions[0] 下的 `version:`（6 空格缩进）
sed_inplace -E "s/^      version: .*/      version: ${ESCAPED_CHART_VERSION}/" "$MODULE_PLUGIN_FILE"

# values.yaml：所有以 "# jaeger-tag" 标记结尾的 tag 行（3 个 Jaeger 镜像共用同一 tag）
sed_inplace -E "s/^([[:space:]]*)tag: .* # jaeger-tag$/\1tag: \"${ESCAPED_IMAGE_TAG}\" # jaeger-tag/" "$VALUES_FILE"

echo "已更新 chart 版本为：${CHART_VERSION}（Jaeger 版本：${JAEGER_VERSION}，Jaeger 镜像 tag：${IMAGE_TAG}）"
echo "  - ${CHART_FILE}"
echo "  - ${MODULE_PLUGIN_FILE}"
echo "  - ${VALUES_FILE}"
