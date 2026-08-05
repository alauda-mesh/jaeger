#!/usr/bin/env bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0
# 步骤 1b / 步骤 5：调内网扫描服务扫当前轮镜像，并按修复责任分类。
# 用法: scan-images.sh [轮次]   缺省用状态里的 ROUND
# 分类:
#   OS_REPORT_ONLY  os 包（基础镜像层）                    → 不修复，如实报告
#   OAUTH2_REPORT   oauth2-proxy 镜像的全部漏洞（第三方）  → 只扫不修，如实报告
#   GO_STDLIB       go 二进制的 stdlib                    → 升级 workflow 的 go-version
#   GO_MODULE       go 二进制的依赖库                      → 升级 go.mod（三个 jaeger 镜像
#                     共用仓库根 go.mod，已按包聚合去重，一次修复覆盖三个镜像）
#   UNKNOWN         其他                                  → 人工判断
# 输出: 每镜像明细 + 修复目标聚合（go.mod 目标 / stdlib 目标 + 当前 workflow go-version）
#       + SUMMARY + RESULT: CLEAN|REPORT_ONLY|FIX_NEEDED
# 退出码: 0=扫描完成（无论结论） 1=失败
# 注意: 服务端要拉镜像再扫，首扫可能几分钟，调用方把 Bash timeout 设为 600000。
# 环境变量: SCAN_API（直接指定服务，跳过主备探测）、MAX_ATTEMPTS=3、RETRY_DELAY=15、SCAN_TIMEOUT=240

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-15}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-240}"

# 服务是否可达：能返回任意 HTTP 状态码即算在线（连接拒绝/超时返回 000）
probe_api() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -m 10 "$1/" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "000" ]]
}

main() {
  repo_root
  load_state
  command -v jq >/dev/null 2>&1 || die "找不到 jq"

  local N="${1:-$ROUND}"
  local IMG_TSV="$STATE_DIR/images-round${N}.tsv"
  [[ -s "$IMG_TSV" ]] || die "没有第 ${N} 轮镜像清单: $IMG_TSV（第 1 轮先执行 resolve-input.sh；回归轮先执行 watch-pr.sh）"

  # ---------- 选定扫描服务：优先主地址，失效切备（SCAN_API 显式指定时跳过探测） ----------
  local -a APIS=()
  if [[ -n "${SCAN_API:-}" ]]; then
    APIS=("$SCAN_API")
    info "使用显式指定的扫描服务: $SCAN_API"
  else
    if probe_api "$SCAN_API_PRIMARY"; then
      APIS=("$SCAN_API_PRIMARY" "$SCAN_API_BACKUP")
      info "使用主扫描服务: $SCAN_API_PRIMARY（备用: $SCAN_API_BACKUP）"
    elif probe_api "$SCAN_API_BACKUP"; then
      APIS=("$SCAN_API_BACKUP")
      warn "主扫描服务不可达（$SCAN_API_PRIMARY），切换到备用: $SCAN_API_BACKUP"
    else
      die "主备扫描服务均不可达: $SCAN_API_PRIMARY / $SCAN_API_BACKUP"
    fi
  fi

  local SCAN_DIR="$STATE_DIR/scans/round${N}"
  mkdir -p "$SCAN_DIR"
  local TSV="$SCAN_DIR/vulns.tsv"
  : >"$TSV"

  # ---------- 逐镜像扫描（同一镜像可能来自多个输入，去重后扫描） ----------
  local imgcat img short out resp encoded url api i rows n api_idx=0
  while IFS=$'\t' read -r imgcat img; do
    short="$(img_repo "$img")"
    out="$SCAN_DIR/$(img_slug "$img").json"

    info "扫描 ${img} ..."
    encoded="$(jq -rn --arg v "$img" '$v|@uri')"
    resp=""
    while [[ -z "$resp" && "$api_idx" -lt ${#APIS[@]} ]]; do
      api="${APIS[$api_idx]}"
      url="${api}/image/vulnerability/custom?image_full_address=${encoded}&trivy_db_date=latest&severity=low&vulnerability_type=os%2Clibrary&version=v4.4.0"
      for i in $(seq 1 "$MAX_ATTEMPTS"); do
        if resp="$(curl -sS --fail --max-time "$SCAN_TIMEOUT" -H 'accept: application/json' "$url")" \
           && jq -e 'has("os") and has("lang")' <<<"$resp" >/dev/null 2>&1; then
          break
        fi
        resp=""
        [[ "$i" -lt "$MAX_ATTEMPTS" ]] && { warn "本次扫描失败，${RETRY_DELAY}s 后重试（$i/$MAX_ATTEMPTS）"; sleep "$RETRY_DELAY"; }
      done
      # 当前服务连续失败：有备用则切换（切换持久化，后续镜像直接用新服务）
      if [[ -z "$resp" ]]; then
        api_idx=$((api_idx + 1))
        [[ "$api_idx" -lt ${#APIS[@]} ]] && warn "服务 $api 连续 $MAX_ATTEMPTS 次失败，切换到 ${APIS[$api_idx]}"
      fi
    done
    [[ -n "$resp" ]] || die "所有扫描服务均连续 $MAX_ATTEMPTS 次失败: $img"
    printf '%s\n' "$resp" >"$out"

    # 提取为 TSV: 镜像短名/分类/包/装机版本/修复候选(逗号分隔,去v前缀)/CVE/严重度
    # 注: 服务对无修复版本返回字符串 "null"，要当空处理，否则会算出 @vnull 的假目标
    rows="$(jq -r --arg repo "$short" --arg impcat "$imgcat" '
      def fixes: [(.FixedVersion // "") | split(",")[] | gsub("^\\s+|\\s+$";"") | sub("^v";"") | select(.!="" and .!="null")] | unique | join(",");
      def cat: if $impcat == "REPORT" then "OAUTH2_REPORT"
               elif .__src == "os" then "OS_REPORT_ONLY"
               elif .PkgName == "stdlib" then "GO_STDLIB"
               elif ((.Target // "") | contains("/")) then "GO_MODULE"
               else "UNKNOWN" end;
      ( [(.os // [])[] | . + {__src:"os"}] + [(.lang // [])[] | . + {__src:"lang"}] )
      | .[] | [$repo, cat, .PkgName, (.InstalledVersion // "?"), fixes, .VulnerabilityID, (.Severity // "?")] | @tsv' "$out")"

    # 同一漏洞可能按 Target 重复出现，按行去重
    n=0
    if [[ -n "$rows" ]]; then
      rows="$(sort -u <<<"$rows")"
      printf '%s\n' "$rows" >>"$TSV"
      n="$(grep -c . <<<"$rows")"
    fi
    echo
    echo "--- ${img}（漏洞 ${n} 条$([[ "$imgcat" == REPORT ]] && echo "，只扫不修")）---"
    [[ -n "$rows" ]] && sort <<<"$rows" | awk -F'\t' \
      '{printf "  [%s] %s %s %s %s → %s\n", $2, $3, $6, $7, $4, ($5 == "" ? "（无修复版本）" : $5)}'
  done < <(cut -f3,4 "$IMG_TSV" | sort -u)

  sort -u "$TSV" -o "$TSV"
  count_cat() { awk -F'\t' -v c="$1" '$2 == c' "$TSV" | grep -c . || true; }
  local TOTAL GOMOD STDLIB OS OAUTH UNK
  TOTAL="$(grep -c . "$TSV" || true)"
  GOMOD="$(count_cat GO_MODULE)"; STDLIB="$(count_cat GO_STDLIB)"
  OS="$(count_cat OS_REPORT_ONLY)"; OAUTH="$(count_cat OAUTH2_REPORT)"; UNK="$(count_cat UNKNOWN)"

  # ---------- 聚合修复目标（GO_MODULE 三镜像共用 go.mod，按包去重） ----------
  if awk -F'\t' '$2=="GO_MODULE" || $2=="GO_STDLIB"' "$TSV" | grep -q .; then
    echo
    echo "--- 修复目标（基线分支 $BASE_BRANCH）---"
    # 当前 go-version：回归轮优先读修复 worktree 里的值（已含上轮修改），首轮读主工作区
    local wf_file="$ROOT/$WORKFLOW_FILE" cur_gover
    [[ -f "$(worktree_dir)/$WORKFLOW_FILE" ]] && wf_file="$(worktree_dir)/$WORKFLOW_FILE"
    cur_gover="$(extract_go_version "$wf_file")"
    echo "  当前 workflow go-version: ${cur_gover:-（未能从 $wf_file 提取）}"

    local stdlib_rows inst cands pkg cves_fix cves_nofix target
    stdlib_rows="$(awk -F'\t' '$2=="GO_STDLIB"' "$TSV" | cut -f3- | sort -u)"
    if [[ -n "$stdlib_rows" ]]; then
      inst="$(head -1 <<<"$stdlib_rows" | cut -f2)"
      cands="$(cut -f3 <<<"$stdlib_rows" | tr ',' '\n' | grep -v '^$' | sort -uV | paste -sd'/' -)"
      echo "  [stdlib] 构建 go ${inst}  CVE×$(grep -c . <<<"$stdlib_rows")  修复候选: ${cands:-（无）} → update-go-version.sh X.Y.Z（优先同 minor 的 patch；跨 minor 须同步 go.mod 并在最终报告中着重说明）"
    fi

    while IFS=$'\t' read -r pkg; do
      inst="$(awk -F'\t' -v p="$pkg" '$2=="GO_MODULE" && $3==p {print $4; exit}' "$TSV")"
      cves_fix="$(awk -F'\t' -v p="$pkg" '$2=="GO_MODULE" && $3==p && $5!="" {print $6}' "$TSV" | sort -u | grep -c . || true)"
      cves_nofix="$(awk -F'\t' -v p="$pkg" '$2=="GO_MODULE" && $3==p && $5=="" {print $6}' "$TSV" | sort -u | grep -c . || true)"
      cands="$(awk -F'\t' -v p="$pkg" '$2=="GO_MODULE" && $3==p {print $5}' "$TSV" \
        | tr ',' '\n' | grep -v '^$' | sort -uV || true)"
      if [[ -n "$cands" ]]; then
        target="$(tail -1 <<<"$cands")"
        echo "  [go.mod] $pkg $inst  CVE×${cves_fix}$([[ "$cves_nofix" -gt 0 ]] && echo "（另 ${cves_nofix} 个无修复版本）")  候选: $(paste -sd'/' - <<<"$cands")  → go get ${pkg}@v${target}"
      else
        echo "  [go.mod] $pkg $inst  CVE×${cves_nofix}  （无修复版本，升级修不了，最终汇报中如实说明）"
      fi
    done < <(awk -F'\t' '$2=="GO_MODULE" {print $3}' "$TSV" | sort -u)
  fi

  echo
  echo "SUMMARY: ROUND=${N} TOTAL=${TOTAL} GO_MODULE=${GOMOD} GO_STDLIB=${STDLIB} OAUTH2_REPORT=${OAUTH} OS_REPORT_ONLY=${OS} UNKNOWN=${UNK}"
  # 可执行修复 = 有修复候选的 GO_MODULE / GO_STDLIB，或需人工判断的 UNKNOWN
  local FIXABLE
  FIXABLE="$(awk -F'\t' '(($2=="GO_MODULE" || $2=="GO_STDLIB") && $5!="") || $2=="UNKNOWN"' "$TSV" | grep -c . || true)"
  if [[ "$TOTAL" -eq 0 ]]; then
    echo "RESULT: CLEAN"
  elif [[ "$FIXABLE" -gt 0 ]]; then
    echo "RESULT: FIX_NEEDED"
  else
    echo "RESULT: REPORT_ONLY（剩余均为不修复项：os 级 / oauth2-proxy / 无修复版本的条目）"
  fi
  echo "明细 TSV: $TSV"
}

main "$@"
