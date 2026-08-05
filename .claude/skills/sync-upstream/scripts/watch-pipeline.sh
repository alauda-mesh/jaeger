#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# 步骤 5：监控 PR 流水线（建议用后台方式运行）。
#   阶段 1：等待 Alauda Build Jaeger（产物流水线）针对 PR 最新 head 的 run 完成，
#           成功时输出本次 PR 构建的镜像与 chart 地址；
#   阶段 2：等待全部 PR checks 收敛；已知的 fork 环境性失败仅记 WARN，不算失败。
# 每轮都会重取 PR 最新 head，监控期间 push 修复无需重启本脚本。
#
# 用法：watch-pipeline.sh <PR编号>    环境变量 WATCH_TIMEOUT_MINUTES 可调总超时（默认 60）
# 退出码：0=PIPELINE_SUCCESS；2=PIPELINE_FAILED；3=PIPELINE_TIMEOUT；4=PIPELINE_NOT_FOUND

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[ $# -eq 1 ] || die "用法：watch-pipeline.sh <PR编号>"
PR="$1"
WORKFLOW="alauda-build-jaeger.yaml"
POLL_SECONDS=60
TIMEOUT_MINUTES="${WATCH_TIMEOUT_MINUTES:-60}"
# 已知与 fork 场景相关、非同步引入的失败检查项：命中时仅记 WARN。
# dco-check 对同步 PR 结构性失败：它全量检查 PR 相对 main 的所有 commit（--no-merges），
# 上游历史 commit 存在 sign-off 与作者名不一致/缺失的情况，fork 无法改写上游历史；
# 自建 commit 脚本均已带 -s，不会额外添乱。
KNOWN_ENV_FAIL_REGEX='^(Coverage Gate|Metrics Comparison|All CI Checks Passed)$|dependency-review|dco-check'

DEADLINE=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
NOT_FOUND_DEADLINE=$(( $(date +%s) + 300 ))   # 5 分钟内找不到 run 视为未触发

check_deadline() {
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        info "等待超时（${TIMEOUT_MINUTES} 分钟）：$1"
        if [ -n "${RUN_URL:-}" ]; then
            info "Alauda Build Jaeger run：${RUN_URL}"
        fi
        info "可稍后重跑 watch-pipeline.sh ${PR} 继续等待"
        echo "RESULT=PIPELINE_TIMEOUT"
        exit 3
    fi
}

info "监控 ${FORK_REPO} PR #${PR}（总超时 ${TIMEOUT_MINUTES} 分钟）"

# ---------- 阶段 1：等待 Alauda Build Jaeger ----------
RUN_ID=""; RUN_NUMBER=""; RUN_STATUS=""; RUN_CONCLUSION=""; RUN_URL=""
while :; do
    if ! HEAD_SHA=$(gh_retry pr view "$PR" --repo "$FORK_REPO" --json headRefOid --jq '.headRefOid'); then
        info "获取 PR head 失败（gh 网络波动？），稍后重试"
        check_deadline "获取 PR head"
        sleep "$POLL_SECONDS"
        continue
    fi
    RUN_LINE=$(gh_retry run list --repo "$FORK_REPO" --workflow "$WORKFLOW" \
        --limit 20 --json databaseId,number,headSha,status,conclusion,url \
        --jq ".[] | select(.headSha==\"${HEAD_SHA}\") | [.databaseId, .number, .status, (.conclusion // \"\"), .url] | @tsv" \
        | head -n 1) || RUN_LINE=""
    if [ -n "$RUN_LINE" ]; then
        IFS=$'\t' read -r RUN_ID RUN_NUMBER RUN_STATUS RUN_CONCLUSION RUN_URL <<< "$RUN_LINE"
        if [ "$RUN_STATUS" = "completed" ]; then
            break
        fi
        info "Alauda Build Jaeger run #${RUN_NUMBER} 状态：${RUN_STATUS}（${RUN_URL}）"
    else
        if [ "$(date +%s)" -ge "$NOT_FOUND_DEADLINE" ]; then
            info "5 分钟内未发现针对 head ${HEAD_SHA:0:8} 的 Alauda Build Jaeger run"
            info "排查方向：self-hosted runner 是否在线；PR diff 是否命中 workflow paths（纯 .md 改动不触发）"
            echo "RESULT=PIPELINE_NOT_FOUND"
            exit 4
        fi
        info "尚未发现针对 head ${HEAD_SHA:0:8} 的 run，继续等待..."
    fi
    check_deadline "等待 Alauda Build Jaeger 完成"
    sleep "$POLL_SECONDS"
done

if [ "$RUN_CONCLUSION" != "success" ]; then
    info "Alauda Build Jaeger run #${RUN_NUMBER} 结论：${RUN_CONCLUSION}（${RUN_URL}）"
    info "失败 job："
    gh_retry run view "$RUN_ID" --repo "$FORK_REPO" --json jobs \
        --jq '.jobs[] | select(.conclusion=="failure") | "  - " + .name' || true
    echo "---- 失败日志摘要（末尾 150 行）----"
    gh run view "$RUN_ID" --repo "$FORK_REPO" --log-failed 2>/dev/null | tail -n 150 || true
    echo "---- 日志结束 ----"
    echo "RESULT=PIPELINE_FAILED"
    exit 2
fi

info "Alauda Build Jaeger run #${RUN_NUMBER} 成功（${RUN_URL}）"

# 产物地址（拼接规则与 CI determine-version job 一致；本地工作区即 PR head 分支）
APP_VERSION=$(sed -nE 's/^appVersion:[[:space:]]*"?([^"]+)"?.*$/\1/p' alauda/jaeger-cluster-plugin/Chart.yaml)
CHART_BASE=$(sed -nE 's/^version:[[:space:]]*v?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' alauda/jaeger-cluster-plugin/Chart.yaml)
CHART_VERSION="v${CHART_BASE}-pr.${PR}.${RUN_NUMBER}"
IMAGE_TAG="${APP_VERSION}-${CHART_VERSION#v}"
info "本次 PR 构建产物："
printf '  build-harbor.alauda.cn/asm/%s\n' \
    "jaeger:${IMAGE_TAG}" \
    "jaeger-es-rollover:${IMAGE_TAG}" \
    "jaeger-es-index-cleaner:${IMAGE_TAG}" \
    "jaeger-cluster-plugin:${CHART_VERSION}"

# ---------- 阶段 2：等待全部 PR checks 收敛 ----------
CHECKS_TSV=""
while :; do
    CHECKS_TSV=$(gh_retry pr checks "$PR" --repo "$FORK_REPO" --json name,bucket,link \
        --jq '.[] | [.bucket, .name, .link] | @tsv') || CHECKS_TSV=""
    TOTAL=$(printf '%s\n' "$CHECKS_TSV" | grep -c . || true)
    PENDING=$(printf '%s\n' "$CHECKS_TSV" | grep -c '^pending' || true)
    # 上游 CI 由 orchestrator 分阶段注册 check，总数过少说明尚未注册完，继续等待
    if [ "$TOTAL" -ge 10 ] && [ "$PENDING" -eq 0 ]; then
        break
    fi
    info "PR checks：共 ${TOTAL} 项，pending ${PENDING} 项，继续等待..."
    check_deadline "等待全部 PR checks 收敛"
    sleep "$POLL_SECONDS"
done

REAL_FAILS=""
WARN_FAILS=""
while IFS=$'\t' read -r bucket name link; do
    if [ -z "$bucket" ]; then
        continue
    fi
    case "$bucket" in
        fail|cancel)
            if printf '%s' "$name" | grep -qE "$KNOWN_ENV_FAIL_REGEX"; then
                WARN_FAILS+="  [WARN] ${name}（已知 fork 环境问题，非同步引入）${link:+ }${link}"$'\n'
            else
                REAL_FAILS+="  [FAIL] ${name}${link:+ }${link}"$'\n'
            fi
            ;;
    esac
done <<< "$CHECKS_TSV"

if [ -n "$WARN_FAILS" ]; then
    info "已知环境性失败（WARN，需写入最终汇报）："
    printf '%s' "$WARN_FAILS"
fi
if [ -n "$REAL_FAILS" ]; then
    info "存在非预期的失败 checks："
    printf '%s' "$REAL_FAILS"
    info "用 gh run view <run-id> --repo ${FORK_REPO} --log-failed 查看对应日志"
    echo "RESULT=PIPELINE_FAILED"
    exit 2
fi

info "全部 PR checks 通过（WARN 项除外）"
echo "RESULT=PIPELINE_SUCCESS"
