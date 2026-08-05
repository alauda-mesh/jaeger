#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0
# 步骤 4：监控修复 PR 触发的 Alauda Build Jaeger run，成功后收集新镜像供回归扫描。
# 按 PR 当前 head sha 精确匹配 run（回归轮多次 push 也不会误拿旧 run）。
# 成功: ROUND+1，生成 images-round<N+1>.tsv（PR 构建的镜像，含 oauth2-proxy）；
#       并汇总 PR 上社区 CI check 状态（fork 上 best-effort，失败不阻塞镜像产出，如实报告）。
# 退出码: 0=构建成功  1=前置失败  2=run 失败（附失败日志摘要）  3=等待超时  4=找不到 run
# 环境变量: FIX_WATCH_INTERVAL=60  FIX_WATCH_TIMEOUT=5400  FIX_WATCH_APPEAR_TIMEOUT=300
# 注意: 多平台镜像构建通常 30~60 分钟，必须用后台方式运行（Bash 的 run_in_background: true）。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INTERVAL="${FIX_WATCH_INTERVAL:-60}"
TIMEOUT="${FIX_WATCH_TIMEOUT:-5400}"
APPEAR_TIMEOUT="${FIX_WATCH_APPEAR_TIMEOUT:-300}"

main() {
  repo_root
  load_state
  require_gh
  command -v jq >/dev/null 2>&1 || die "找不到 jq"
  [[ -n "${PR_NUMBER:-}" ]] || die "状态中没有 PR_NUMBER（先执行 create-pr.sh）"

  local state sha
  state="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
  [[ "$state" == "OPEN" ]] || die "PR #$PR_NUMBER 状态为 $state，不在监控范围（预期 OPEN）"
  sha="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid --jq .headRefOid)"

  # ---------- 等待 head sha 对应的 run 出现 ----------
  info "等待 PR #$PR_NUMBER（head ${sha:0:10}）的 '$WORKFLOW_NAME' run 出现（最长 ${APPEAR_TIMEOUT}s）..."
  local start rid
  start="$(date +%s)"
  while :; do
    rid="$(gh run list --repo "$REPO" --workflow "$WORKFLOW_NAME" --branch "$FIX_BRANCH" --limit 10 \
      --json databaseId,headSha --jq "[.[] | select(.headSha == \"$sha\")][0].databaseId // empty" 2>/dev/null || true)"
    [[ -n "$rid" ]] && break
    if (( $(date +%s) - start > APPEAR_TIMEOUT )); then
      echo "RESULT: RUN_NOT_FOUND PR #$PR_NUMBER 在 ${APPEAR_TIMEOUT}s 内没有出现对应 run"
      echo "  可能原因: 变更未命中 workflow 的 paths 过滤 / self-hosted runner 不在线"
      exit 4
    fi
    sleep 10
  done
  info "PR #$PR_NUMBER → run $rid"

  # ---------- 轮询直至完成 ----------
  local st cc
  start="$(date +%s)"
  while :; do
    read -r st cc < <(gh run view "$rid" --repo "$REPO" --json status,conclusion \
      --jq '"\(.status) \(.conclusion // "-")"' 2>/dev/null || echo "unknown -")
    [[ "$st" == "completed" ]] && break
    if (( $(date +%s) - start > TIMEOUT )); then
      echo "RESULT: PIPELINE_TIMEOUT 等待超过 ${TIMEOUT}s run $rid 仍未完成（当前 status=$st），请稍后重跑本脚本或人工查看"
      exit 3
    fi
    sleep "$INTERVAL"
  done
  echo "[$(date -u +%H:%M:%S)] run $rid completed: $cc"

  # ---------- 失败：给出失败 step 与日志摘要 ----------
  if [[ "$cc" != "success" ]]; then
    echo
    echo "FAIL: PR #$PR_NUMBER run $rid conclusion=$cc"
    echo "  失败 step 概览:"
    gh run view "$rid" --repo "$REPO" 2>/dev/null | grep -E '^(X|✓|-|\*)' | head -15 | sed 's/^/    /' || true
    echo "  失败日志摘要（完整: gh run view $rid --repo $REPO --log-failed）:"
    gh run view "$rid" --repo "$REPO" --log-failed 2>/dev/null | tail -80 | sed 's/^/    /' \
      || echo "    （拉取失败日志出错，请人工查看）"
    echo
    echo "RESULT: PIPELINE_FAILED（分析原因后在原 worktree 追加 commit 修复，重跑 create-pr.sh 与本脚本）"
    exit 2
  fi

  # ---------- 成功：收集新镜像，写回归轮清单 ----------
  local NEXT=$((ROUND + 1))
  local IMG_TSV="$STATE_DIR/images-round${NEXT}.tsv"
  : >"$IMG_TSV"   # 重跑时整体重建，保持幂等
  local imgs img cat
  imgs="$(extract_build_images "$rid")"
  [[ -n "$imgs" ]] || die "run $rid 成功但未能提取 BUILD_IMAGES，无法生成回归扫描清单"
  while IFS= read -r img; do
    cat="$(repo_category "$(img_repo "$img")")"
    [[ "$cat" == IGNORE ]] && continue
    printf '%s\t%s\t%s\t%s\n' "$NEXT" "run-$rid" "$cat" "$img" >>"$IMG_TSV"
  done < <(jq -r '.[]' <<<"$imgs")
  [[ -s "$IMG_TSV" ]] || die "run $rid 的 BUILD_IMAGES 中没有处理范围内的镜像"
  set_state ROUND "$NEXT"

  echo "OK: PR #$PR_NUMBER 构建成功，新镜像:"
  awk -F'\t' '{printf "    [%s] %s\n", $3, $4}' "$IMG_TSV"

  # ---------- 社区 CI check 汇总（fork 上 best-effort，如实报告，不影响退出码） ----------
  echo
  echo "PR 其他 check 状态（Alauda Build Jaeger 之外的社区 CI，fork 上失败不阻塞镜像产出）:"
  gh pr view "$PR_NUMBER" --repo "$REPO" --json statusCheckRollup \
    --jq '.statusCheckRollup[] | select((.conclusion // .state) as $c | ["SUCCESS","SKIPPED","NEUTRAL"] | index($c) | not) | "  \(.name // .context): \(.conclusion // .state)"' \
    2>/dev/null | sort -u | head -20 || echo "  （读取 check 状态失败）"
  echo "  （为空则全部通过/跳过；FAILURE 项需分析是否与本次修复有关，如实写入最终报告）"

  echo
  echo "RESULT: BUILD_SUCCESS"
  echo "回归轮镜像清单: $IMG_TSV"
  echo "下一步: 执行 scan-images.sh 做第 ${NEXT} 轮回归扫描（Bash timeout 600000）"
}

main "$@"
