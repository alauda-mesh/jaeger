#!/usr/bin/env bash
# 步骤 3：push 修复分支并创建 PR（base = 基线分支，--repo alauda-mesh/jaeger，不能推社区上游）。
# 用法: create-pr.sh <PR正文文件>
# 幂等：修复分支已有 open PR 时直接复用（回归轮 push 新 commit 即可）。
# 输出: PR_NUMBER= / PR_URL=，并记入状态（watch-pr.sh 用）。
# 环境变量: TITLE 覆盖默认 PR 标题（默认 fix: CVE fixes on <UTC日期>）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  load_state
  require_gh

  local BODY_FILE="${1:-}"
  [[ -n "$BODY_FILE" && -f "$BODY_FILE" ]] || die "PR 正文文件不存在: ${BODY_FILE:-（未提供）}（先写好正文再执行）"
  [[ -n "${FIX_BRANCH:-}" ]] || die "状态中没有 FIX_BRANCH（先执行 create-fix-branch.sh）"
  origin_is_alauda || die "origin 不是 $REPO，拒绝 push/建 PR（防止误推社区上游）"

  local WT; WT="$(resolve_worktree)"
  cd "$WT"
  [[ "$(git branch --show-current)" == "$FIX_BRANCH" ]] || die "worktree 当前分支不是 $FIX_BRANCH"
  [[ -z "$(git status --porcelain)" ]] || die "worktree 有未提交改动，请先 commit（git commit -s，禁止 amend，一律新建 commit）"

  git fetch -q origin "refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" 2>/dev/null || true
  local n
  n="$(git rev-list --count "refs/remotes/origin/$BASE_BRANCH..HEAD")"
  [[ "$n" -ge 1 ]] || die "相对 origin/$BASE_BRANCH 没有新 commit，无内容可提 PR"
  # DCO 检查：本 skill 产生的 commit 必须带 Signed-off-by（社区 CI 的 dco-check 校验）
  local unsigned
  unsigned="$(git log --format='%h %(trailers:key=Signed-off-by,valueonly)' "refs/remotes/origin/$BASE_BRANCH..HEAD" \
    | awk 'NF==1 {print $1}' | paste -sd' ' -)"
  [[ -z "$unsigned" ]] || die "以下 commit 缺少 Signed-off-by（用 git commit -s 重新提交，禁止 amend）: $unsigned"

  info "push $FIX_BRANCH 到 origin ..."
  git push -u origin "$FIX_BRANCH" || die "push 失败"

  local PR_INFO
  PR_INFO="$(gh pr list --repo "$REPO" --head "$FIX_BRANCH" --state open \
    --json number,url --jq '.[0] | "\(.number) \(.url)"' 2>/dev/null || true)"
  if [[ -n "$PR_INFO" && "$PR_INFO" != "null null" ]]; then
    info "分支 $FIX_BRANCH 已有 open PR，直接复用"
  else
    # 标题遵循仓库惯例：type: 后首词大写
    local d TITLE_DEFAULT
    d="${FIX_BRANCH##*/cve-}"
    TITLE_DEFAULT="fix: CVE fixes on ${d:0:4}-${d:4:2}-${d:6:2}"
    gh pr create --repo "$REPO" --base "$BASE_BRANCH" --head "$FIX_BRANCH" \
      --title "${TITLE:-$TITLE_DEFAULT}" --body-file "$BODY_FILE" >/dev/null || die "创建 PR 失败"
    PR_INFO="$(gh pr list --repo "$REPO" --head "$FIX_BRANCH" --state open \
      --json number,url --jq '.[0] | "\(.number) \(.url)"')"
  fi

  local PR_NUMBER="${PR_INFO%% *}" PR_URL="${PR_INFO##* }"
  set_state PR_NUMBER "$PR_NUMBER"
  set_state PR_URL "$PR_URL"

  echo
  echo "PR_NUMBER=$PR_NUMBER"
  echo "PR_URL=$PR_URL"
  echo "下一步: 后台执行 watch-pr.sh 监控流水线（Bash 的 run_in_background: true）"
}

main "$@"
