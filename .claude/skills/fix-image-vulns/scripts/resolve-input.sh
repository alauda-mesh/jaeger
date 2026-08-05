#!/usr/bin/env bash
# 步骤 1a：解析输入（流水线 run 或镜像地址）→ 待扫描镜像清单，初始化本次任务状态。
# 用法: resolve-input.sh <RUN_ID|run URL|镜像地址> ...
#   - RUN_ID / run URL：只接受 Alauda Build Jaeger 流水线的成功 run，
#     从其 "Output images" job 日志提取 BUILD_IMAGES JSON 数组；
#   - 镜像地址（形如 build-harbor.alauda.cn/asm/jaeger:2.20.0-2.1.0-pr.7.26）：直接纳入，
#     两类输入可混用，多个 run/镜像取并集去重。
# 镜像分类: jaeger/jaeger-es-rollover/jaeger-es-index-cleaner → FIX（修复）；
#           oauth2-proxy → REPORT（只扫不修）；jaeger-cluster-plugin 及其他 → 忽略并警告。
# 修复基线 = 主工作区当前检出分支（记入状态，create-fix-branch.sh 使用）。
# 退出码: 0=OK  1=失败
# 注意: 提取 run 日志需要几十秒，调用方把 Bash timeout 设为 300000。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  command -v jq >/dev/null 2>&1 || die "找不到 jq"
  [[ $# -ge 1 ]] || die "用法: resolve-input.sh <RUN_ID|run URL|镜像地址> ..."

  # ---------- 参数分流：run 与镜像 ----------
  local -a RUNS=() IMAGES=()
  local arg id
  for arg in "$@"; do
    if [[ "$arg" =~ /runs/([0-9]+) ]]; then
      RUNS+=("${BASH_REMATCH[1]}")
    elif [[ "$arg" =~ ^[0-9]+$ ]]; then
      RUNS+=("$arg")
    elif [[ "$arg" == */*:* ]]; then
      IMAGES+=("$arg")
    else
      die "无法识别的参数: $arg（应为 run ID、run URL 或带 tag 的完整镜像地址）"
    fi
  done
  [[ ${#RUNS[@]} -gt 0 ]] && require_gh

  # ---------- 残留上次任务状态时安全清理：worktree 有未提交改动则终止，交人工确认 ----------
  if [[ -f "$STATE_FILE" ]]; then
    local wt; wt="$(worktree_dir)"
    if [[ -d "$wt" ]]; then
      if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
        die "上次任务残留 worktree 有未提交改动: $wt
请人工确认（保留则提交，放弃则 git worktree remove --force）后重跑"
      fi
      info "清理上次任务的干净 worktree: $wt"
      git worktree remove --force "$wt" >/dev/null 2>&1 || true
    fi
    git worktree prune >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR" && mkdir -p "$STATE_DIR"
  fi

  # ---------- 修复基线 = 当前检出分支 ----------
  local BASE_BRANCH
  BASE_BRANCH="$(git branch --show-current)"
  [[ -n "$BASE_BRANCH" ]] || die "主工作区处于 detached HEAD，请先检出一个分支（通常是 main）再重跑"

  # ---------- run → 镜像 ----------
  local meta wf status conclusion imgs
  for id in "${RUNS[@]}"; do
    meta="$(gh run view "$id" --repo "$REPO" --json workflowName,status,conclusion,displayTitle,url)" \
      || die "读取 run $id 失败（--repo $REPO）"
    wf="$(jq -r .workflowName <<<"$meta")"
    status="$(jq -r .status <<<"$meta")"
    conclusion="$(jq -r .conclusion <<<"$meta")"
    [[ "$wf" == "$WORKFLOW_NAME" ]] \
      || die "run $id 属于工作流「$wf」，本 skill 只处理 $WORKFLOW_NAME"
    [[ "$status" == "completed" && "$conclusion" == "success" ]] \
      || die "run $id 未成功完成（status=$status conclusion=$conclusion），镜像可能不完整，不纳入扫描"

    info "拉取 run $id 的 Output images job 日志提取镜像 ..."
    imgs="$(extract_build_images "$id")"
    [[ -n "$imgs" ]] || die "未能从 run $id 提取 BUILD_IMAGES（没有 'Output images' job 或日志中无 BUILD_IMAGES= 行）"
    jq -e 'type == "array" and length > 0' <<<"$imgs" >/dev/null \
      || die "run $id 的 BUILD_IMAGES 不是有效的非空 JSON 数组: $imgs"

    echo "run $id [$(jq -r .displayTitle <<<"$meta")] 输出镜像:"
    jq -r '.[] | "    " + .' <<<"$imgs"
    while IFS= read -r img; do
      IMAGES+=("$img|run-$id")
    done < <(jq -r '.[]' <<<"$imgs")
  done

  # ---------- 镜像分类去重，写第 1 轮清单 ----------
  local IMG_TSV="$STATE_DIR/images-round1.tsv"
  : >"$IMG_TSV"
  local -a IGNORED=()
  local entry img src cat
  for entry in "${IMAGES[@]}"; do
    img="${entry%%|*}"
    src="${entry#*|}"; [[ "$src" == "$img" ]] && src="manual"
    cat="$(repo_category "$(img_repo "$img")")"
    if [[ "$cat" == IGNORE ]]; then
      IGNORED+=("$img")
      warn "镜像不在处理范围（jaeger-cluster-plugin 为 chart，其他名称未知），跳过: $img"
      continue
    fi
    printf '1\t%s\t%s\t%s\n' "$src" "$cat" "$img" >>"$IMG_TSV"
  done
  # 同一镜像可能来自多个输入，按（类别,镜像）去重
  sort -u -t$'\t' -k3,4 "$IMG_TSV" -o "$IMG_TSV"
  [[ -s "$IMG_TSV" ]] || die "输入中没有任何在处理范围内的镜像（FIX: $FIX_REPOS；REPORT: $REPORT_REPOS）"

  set_state ROUND 1
  set_state BASE_BRANCH "$BASE_BRANCH"

  echo
  echo "INPUT_RESOLVED"
  echo "修复基线分支: $BASE_BRANCH"
  echo "第 1 轮待扫描镜像（FIX=扫描并修复；REPORT=只扫不修）:"
  awk -F'\t' '{printf "  [%s] %s\n", $3, $4}' "$IMG_TSV"
  [[ ${#IGNORED[@]} -gt 0 ]] && { echo "已跳过（不在处理范围）:"; printf '  %s\n' "${IGNORED[@]}"; }
  echo "下一步: 执行 scan-images.sh 扫描（Bash timeout 设 600000）"
}

main "$@"
