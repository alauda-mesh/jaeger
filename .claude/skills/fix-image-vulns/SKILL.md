---
name: fix-image-vulns
description: 修复 alauda-mesh/jaeger 的 Alauda Build Jaeger 流水线构建的 jaeger 镜像安全漏洞。输入一个或多个流水线 run（ID/URL）或完整镜像地址，完成：解析待扫描镜像清单、调内网扫描服务（主备自动切换）扫描并按修复责任分类、修复（go stdlib → 升 workflow 的 go-version；go.mod 依赖 → 升级库版本，三镜像共用 go.mod 一次修复）、本地构建验证、创建 PR 并监控流水线、回归扫描（最多 3 轮修复）；os 级与 oauth2-proxy 镜像的漏洞只扫描报告不修复。仅限用户显式通过 /fix-image-vulns 调用。
argument-hint: "[RUN_ID | run URL | 镜像地址 ...]，例如: /fix-image-vulns 30991968147"
disable-model-invocation: true
---

# 修复 jaeger 镜像漏洞

对 Alauda Build Jaeger 流水线构建的镜像做漏洞扫描，按修复责任分类处理，直到镜像干净或达到轮次上限。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。

## 参数

- `$ARGUMENTS`：一个或多个流水线 run（纯数字 ID 或 run URL，只接受 **Alauda Build Jaeger** 流水线的成功 run）或带 tag 的完整镜像地址（如 `build-harbor.alauda.cn/asm/jaeger:2.20.0-2.1.0-pr.7.26`），两类可混用。
- 参数里可能混有给助手的备注文字，只把 run/镜像部分传给脚本，备注按用户附加要求执行。
- 参数为空时用 AskUserQuestion 向用户询问，不要自行猜测。

## 背景知识

**镜像与修复责任**（run 输入时从其 `Output images` job 的 `BUILD_IMAGES` 提取清单）：

| 镜像 | 内容 | 漏洞处理 |
| --- | --- | --- |
| asm/jaeger、asm/jaeger-es-rollover、asm/jaeger-es-index-cleaner | go 二进制（共用仓库根 `go.mod`） | stdlib → 升 workflow go-version；依赖库 → 升 go.mod |
| asm/oauth2-proxy | 第三方镜像，随集群插件分发 | **只扫不修**，如实报告（后续处理走 `alauda/README.md` 的 oauth2-proxy 同步流程，不在本 skill 范围） |
| asm/jaeger-cluster-plugin | helm chart，非镜像 | 不纳入 |
| （所有镜像的基础层） | distroless/os 包 | **不修复**，如实报告 |

- 三个 jaeger 镜像共用同一 `go.mod`，漏洞**统一分析、一次修复**即可覆盖三个镜像（scan 脚本已按包聚合去重）。
- **go 版本 pin 机制**：`.github/workflows/alauda-build-jaeger.yaml` 中 setup-go 的 `go-version: X.Y.Z`（固定补丁版）决定编译用的 go 版本。修 stdlib 漏洞就是升这个 pin。升级策略：优先当前 minor 内的 patch；patch 满足不了修复版本要求时才跨 minor，此时须同步升 `go.mod` 的 go directive 等（CI 的 lint-goversion 按 go.mod 校验所有 workflow 的 minor 一致性，脚本会输出配套修改清单），并**在最终报告中着重强调**。pin 附近的注释记录上次 pin 的缘由，升级后要一并改写。
- workflow env 里的 `GOFLAGS: -buildvcs=false` 用于消除主模块伪版本导致的 Trivy 误报——若扫描结果出现 `github.com/jaegertracing/jaeger` 自身的史前 CVE，先检查该 flag 是否还在，而不是去改依赖。
- 修复基线 = 主工作区**当前检出分支**（通常 main）。修复在独立 worktree 中进行，不打扰主工作区。
- **PR 检查分层**：PR 必须让 **Alauda Build Jaeger** 流水线成功（产出回归扫描用的新镜像）；PR 上同时会跑社区 CI（lint/test/coverage 等），在 fork 上属 best-effort——`Coverage Gate`、`Metrics Comparison` 历史上在 fork PR 就失败、不阻塞 merge，但 **dco-check 应保持绿**（本 skill 的 commit 一律 `git commit -s`），其余失败项要分析是否由本次升级引入并如实报告。
- git 规矩：commit 一律 `git commit -s`（DCO），信息格式 `type(scope): Capitalized`；**禁止 amend**，一律新建 commit；**不加** Co-Authored-By / Claude-Session 尾注。gh 命令必须显式 `--repo alauda-mesh/jaeger`（脚本已内置），禁止推社区上游。
- 维护本 skill：`$SKILL_DIR` 下的 `.sh` 同样受仓库 `make lint-license` 校验，新增脚本须先跑 `./scripts/lint/updateLicense.py <文件>` 补标准 license 头再提交，否则 main 与所有 PR 的社区 CI lint 全红。
- 修复轮次上限 **3 轮**（首轮 + 回归后最多再修 2 次），修不完就如实汇报。
- 状态目录 `.tmp/fix-image-vulns/`（gitignore 内），各脚本经 `state.env` 与若干 tsv 串联。

## 步骤 1：漏洞检测

```bash
bash "$SKILL_DIR/scripts/resolve-input.sh" <run|镜像 ...>   # Bash timeout 设 300000（要下载 run 日志）
bash "$SKILL_DIR/scripts/scan-images.sh"                    # Bash timeout 设 600000（服务端拉镜像+扫描）
```

- scan 脚本自动探测内网扫描服务：优先 `192.168.141.42:8888`，不可达或连续失败时切换备用 `192.168.25.100:8888`。
- **无论有无漏洞，都先向用户输出扫描摘要**（每镜像漏洞数、SUMMARY 分类计数、修复目标表）。然后按 `RESULT:` 分支：
  - **CLEAN**：无漏洞，汇报后直接结束；
  - **REPORT_ONLY**：剩余均为不修复项（os 级 / oauth2-proxy / 无修复版本），列出明细并说明不修复的原因，结束；
  - **FIX_NEEDED**：执行步骤 2～5。

## 步骤 2：修复

```bash
bash "$SKILL_DIR/scripts/create-fix-branch.sh"    # 输出 WORKTREE= / BRANCH=
```

本地基线分支领先 origin 时脚本会终止（防止把未 push 的 commit 混进 PR），按提示与用户确认。

**go stdlib**（对照 scan 输出的当前 go-version 与修复候选选定版本，格式 X.Y.Z 不带 go 前缀）：

```bash
bash "$SKILL_DIR/scripts/update-go-version.sh" <X.Y.Z>
```

按脚本 NOTICE 用 Edit 改写 go-version 附近的过时注释（写明本次升级对应的 CVE）。输出 `CROSS_MINOR` 时按清单完成配套修改（go.mod go directive、check-go-version.sh 对齐等），并在最终报告着重说明。

**go.mod 依赖**（升级目标以 scan 输出的"修复目标"表为准；候选没有 v 前缀，`go get` 时要加上）：

```bash
bash "$SKILL_DIR/scripts/gomod-bump.sh" <module@vX.Y.Z> [...]   # timeout 600000；冷缓存首跑建议 run_in_background: true
```

只改了 go-version、没动 go.mod 时，用 `gomod-bump.sh --build-only` 单做构建验证。

修复注意事项：

- 库之间有依赖约束，实际落位版本可能高于扫描给的修复候选，属正常，脚本会打印实际版本；
- `go get` 报 `A@vX requires B@vY, not B@vZ`：把 B 的目标提到 vY 重跑（vY 更高，CVE 覆盖不受影响）；
- 同一发布系列的包版本要对齐，统一取其中最高者。特别地，jaeger 大量依赖 **OTel Collector 组件**（`go.opentelemetry.io/collector/*`，成套发布）：优先只升目标组件，若编译报 API 不匹配，说明需要把相关组件成套升到同一发布批次——参考上游 `jaegertracing/jaeger` main 分支 go.mod 的钉法，变更面大时在 PR 正文说明；
- 落位版本以扫描器给的修复候选为准，**勿基于 advisory 原文自行换用其他修复分支**（LTS/多分支修复线 Go 漏洞库常只收录主线，换线会导致镜像扫描无法清零）；
- 无修复版本的 CVE 升级修不了，记入最终汇报的"未修复项"；
- tidy 后**审查连带升级面**：`git diff go.mod` 检查基础库（grpc、k8s.io、collector 系列等）是否被连带大幅拉升，异常拉升要评估影响或回钉；
- 构建失败时分析原因（版本冲突、新版本要求更高 go、API 变更），能明确解决就解决，拿不准就带着报错向用户提问，不要凭猜测大版本连锁升级；
- go.mod-only 变更本地做构建验证即可，完整 lint/test 交给 PR 上的社区 CI 兜底（见"PR 检查分层"）。

**提交**（在 worktree 内，两类修复各自独立 commit；`git commit -s`，禁止 amend）：

- go.mod：`fix(deps): Bump vulnerable go modules`
- go-version：`ci: Bump Go to X.Y.Z for <CVE编号>`

## 步骤 3：创建 PR

PR 正文写进 scratchpad 临时文件：扫描摘要（镜像、分类计数）+ 修复清单（每项：包/模块、版本变化、覆盖的 CVE）+ 本地构建验证说明 + 不修复项说明（os 级 / oauth2-proxy）+ 结尾一行 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <正文文件>    # 输出 PR_NUMBER= / PR_URL=
```

幂等：修复分支已有 open PR 时复用，回归轮 push 新 commit 后重跑即可。

## 步骤 4：监控 PR 流水线

多平台镜像构建 30～60 分钟，**必须后台运行**（Bash 的 `run_in_background: true`）：

```bash
bash "$SKILL_DIR/scripts/watch-pr.sh"
```

等待期间查进度直接 Read 后台任务的输出文件；不要前台 `sleep` 轮询（harness 会拦截），确需定时等待用 Monitor 工具。

脚本按 PR 当前 head sha 精确匹配 run，成功时自动收集 PR 构建出的新镜像并把轮次 +1，同时汇总社区 CI check 状态。按退出结果处理：

- **BUILD_SUCCESS（0）**：进入步骤 5。输出里列出的社区 CI 失败项要分析：与本次修复相关（如 lint/test 因依赖升级挂掉）则修复；fork 固有失败（Coverage Gate、Metrics Comparison 等）如实记入最终报告即可；
- **PIPELINE_FAILED（2）**：脚本已附失败 step 与日志摘要。**分析失败原因**：是本次修复引入（依赖升级编译错、go-version 拼错或 runner 下载不到）还是环境问题（self-hosted runner、registry、代理）。修复方向拿不准时向用户提问，不要盲目改了就重推；修好后在原 worktree 追加 commit → 重跑 create-pr.sh → 重跑本脚本；
- **PIPELINE_TIMEOUT（3）**：告知用户流水线仍在运行，稍后可重跑本脚本继续等；
- **RUN_NOT_FOUND（4）**：按脚本提示排查，如实告知用户。

社区 CI 失败归因技巧：

- 先判断失败是否继承自基线：`gh run list --repo alauda-mesh/jaeger --branch main --workflow "CI Orchestrator" --limit 3`，base commit 自身就红的项不是本次修复引入的；
- `All CI Checks Passed` 是聚合 check，随任一 stage 失败而红，不单独归因；
- 社区 CI 的 `--log-failed` 输出会被 self-hosted runner 安全代理日志（agentservice / armour / hardenrunner）淹没：先 `gh run view <run> --json jobs` 定位 conclusion=failure 的 job，再按 `--job <id>` 拉日志并 `grep -vE 'agentservice|armour|hardenrunner'` 过滤后找 `Error / ##[error]` 行。

## 步骤 5：回归扫描与迭代

```bash
bash "$SKILL_DIR/scripts/scan-images.sh"    # ROUND 已 +1，自动扫 PR 构建的新镜像
```

- **CLEAN / REPORT_ONLY**：修复完成——先用 `gh pr comment --repo alauda-mesh/jaeger` 把回归扫描结论与社区 CI 失败归因回填到 PR 供 review 参考，再进入最终汇报；
- **FIX_NEEDED**：先分析为什么还有漏洞（上轮目标版本仍带 CVE？升级未生效？新版本引入新漏洞？），再回到步骤 2 继续修——不新建分支，在原 worktree 追加 commit → create-pr.sh push → 后台 watch-pr.sh → 再扫描。

**最多 3 轮修复**。到限仍未清零时停止，如实汇报剩余漏洞、已尝试的措施和失败原因，让用户决策。

## 最终汇报

用清晰列表汇报：

1. 输入（run / 镜像）与解析出的扫描清单；
2. 首轮扫描摘要（总数、分类计数）→ 修复清单（包/模块、版本变化、覆盖的 CVE、commit）→ PR 链接与流水线结果 → 回归扫描结论；
3. oauth2-proxy 镜像扫描结果（如实列出，注明只扫不修，处理途径见 `alauda/README.md`）；
4. 剩余不修复项：os 级漏洞明细、无修复版本或修不掉的项及原因（如实报告，注明不在修复范围）；
5. 社区 CI 中的失败项及归因（fork 固有 / 本次修复引入）；
6. 若 go-version 跨了 minor/大版本，**着重强调**该变化及原因。

不要自行 merge PR，等用户 review。
