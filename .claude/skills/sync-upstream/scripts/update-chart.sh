#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# 步骤 3：更新集群插件版本并提交 —— 调用 chart 自带的 hack/update-version.sh，
# 将 Chart.yaml 的 appVersion 更新为上游 Jaeger 版本、version 更新为 ACP 产品版本，
# 并联动更新 module-plugin.yaml 与 values.yaml 的 jaeger 镜像 tag（oauth2-proxy tag 不动）。
#
# 用法：update-chart.sh <上游tag> <ACP产品版本>    例：update-chart.sh v2.20.0 v2.2.0-r0
# 退出码：0=CHART_UPDATED；1=参数或执行错误

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[ $# -eq 2 ] || die "用法：update-chart.sh <上游tag> <ACP产品版本>（如 v2.20.0 v2.2.0-r0）"
TAG="$1"
ACP_VERSION="$2"
validate_tag "$TAG"
validate_acp_version "$ACP_VERSION"
JAEGER_VERSION="${TAG#v}"

CHART_DIR="alauda/jaeger-cluster-plugin"
bash "${CHART_DIR}/hack/update-version.sh" "$ACP_VERSION" "$JAEGER_VERSION"

git add "${CHART_DIR}/Chart.yaml" "${CHART_DIR}/module-plugin.yaml" "${CHART_DIR}/values.yaml"
if git diff --cached --quiet; then
    info "版本文件无变化（可能已更新过），跳过提交"
else
    git diff --cached --stat
    # -s（Signed-off-by）必须带：上游 dco-check 会检查 PR 中所有非 merge commit 的签名
    git commit -s -m "chore(alauda): bump cluster plugin to ${ACP_VERSION} (jaeger ${JAEGER_VERSION})"
    info "已提交版本更新 commit"
fi

echo "RESULT=CHART_UPDATED"
echo "NEXT=编写 PR 描述文件后运行 scripts/create-pr.sh ${TAG} <目标分支> <PR正文文件>"
