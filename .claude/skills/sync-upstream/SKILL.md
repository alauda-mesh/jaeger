---
name: sync-upstream
description: 同步上游 jaegertracing/jaeger 指定 release tag 到本仓库（alauda-mesh/jaeger fork）的目标分支。完成：merge 上游 tag 并对齐 idl/jaeger-ui submodule（有冲突则解决并汇报）、本地构建验证 jaeger/es-rollover/es-index-cleaner 三个二进制（失败则分析修复）、更新集群插件 Chart 的 appVersion 与 version、创建 PR 到 alauda-mesh/jaeger 并监控流水线（失败则分析修复）、最终汇报并提醒手动更新 oauth2-proxy 镜像。仅限用户显式通过 /sync-upstream 调用。
argument-hint: "[上游tag] [目标分支] [ACP产品版本]，例如: v2.20.0 main v2.2.0-r0"
disable-model-invocation: true
---

# 同步上游代码（jaegertracing/jaeger → alauda-mesh/jaeger）

把上游 https://github.com/jaegertracing/jaeger 的指定 release tag 同步到本仓库的目标分支。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。

## 参数

- 上游 tag：`$0`（形如 `v2.20.0`）
- 目标分支：`$1`（通常为 `main`）
- ACP 产品版本：`$2`（形如 `v2.2.0-r0`，即集群插件 chart 版本）

三个参数都必须明确。若任一为空，用 AskUserQuestion 向用户询问，不要自行猜测。推荐值来源：

- 上游 tag：`git ls-remote --tags https://github.com/jaegertracing/jaeger.git 'v*'` 中最新的正式版本（排除 `^{}` 行与预发布）；
- 目标分支推荐 `main`；
- ACP 产品版本按 `alauda/README.md` Release 章节规则推荐：Jaeger 升级时在当前 `alauda/jaeger-cluster-plugin/Chart.yaml` 的 `version` 基础上递增 minor 并回到 `-r0`（如 `v2.1.0-r0` → `v2.2.0-r0`）。例外：若当前版本尚未正式发版（`git ls-remote --tags origin 'plugin-*'` 中没有对应 `plugin-<版本>` tag），保持当前版本原地升级 Jaeger 也是合理选择（v2.20.0 同步即如此），以用户传入值为准。

## 背景知识

- 本仓库是 jaegertracing/jaeger 的 git fork；脚本会自动维护名为 `upstream` 的 remote。**存在 upstream remote 时 gh 可能把默认仓库解析成上游**，因此所有 gh 操作必须显式 `--repo alauda-mesh/jaeger`（脚本已内置）；绝对不允许向上游仓库推分支或建 PR。
- alauda 定制内容：`alauda/` 目录、`.github/workflows/alauda-build-jaeger.yaml`，以及对以下上游文件的小改动（合并冲突高发区，冲突时"上游新增 + alauda 定制"通常都要保留）：
  - `cmd/jaeger/Dockerfile`、`cmd/es-rollover/Dockerfile`、`cmd/es-index-cleaner/Dockerfile`：`ARG base_image` /（jaeger 还有 `ARG debug_image`）增加了 `=scratch` 默认值；
  - `scripts/makefiles/BuildBinaries.mk`：`build-es-index-cleaner` / `build-es-rollover` 改走 `_build-a-binary-*` 通用规则；
  - `scripts/makefiles/BuildInfo.mk`：ldflags 追加了 `$(LD_EXTRAFLAGS)`。
- `idl`、`jaeger-ui` 是指向上游仓库的 submodule，合并后由脚本 `git submodule update` 对齐到上游 tag 记录的 commit；jaeger-ui 恰好位于 release tag 时，`make build-jaeger` 的 rebuild-ui 会直接下载预构建 UI 资产（curl），无需本地 node 环境。注意 `git submodule status` 的描述只认 annotated tag，而 jaeger-ui 的 release tag 是 lightweight，会显示成 `v1.10.0-NNN-g...` 之类的误导值；判断是否位于 release tag 以 `git -C jaeger-ui describe --tags` 为准（sync/build 脚本均已输出）。
- 版本双轴（详见 `alauda/README.md`）：`Chart.yaml` 的 `appVersion` = 上游 Jaeger 版本（如 `2.20.0`），`version` = 集群插件/ACP 产品版本（如 `v2.2.0-r0`）；统一用 chart 自带的 `hack/update-version.sh` 修改，`values.yaml` 行尾 `# jaeger-tag`、`# oauth2-proxy-tag` 标记不可删除。
- 全程禁止 `git commit --amend`，一律创建新 commit，且 commit 不携带 Co-Authored-By 等 trailer；所有自建 commit 必须带 `Signed-off-by`（`git commit -s`，脚本内的 commit 已内置），上游 dco-check 会检查 PR 内所有非 merge commit 的签名。步骤 4 之前不要 push、不要建 PR；create-pr.sh 只推送同步分支和上游 tag 对象。
- PR 会同时触发上游完整 CI 和 `Alauda Build Jaeger` 流水线。fork 上已知的、并非同步引入的失败项：`Coverage Gate`、`Metrics Comparison`、`dependency-review`、`All CI Checks Passed` 聚合项（以上与 fork 环境有关），以及 `dco-check`（对同步 PR 结构性失败：它全量检查 PR 相对 main 的所有 commit，上游历史 commit 存在 sign-off 与作者名不一致或缺失的情况，fork 无法改写上游历史）。watch-pipeline.sh 会把它们记为 WARN 而不算失败，但要在最终汇报中如实列出。注意 PR #6 是集群插件功能 PR 而非同步 PR，v2.20.0 的 PR #7 才是首个同步 PR，其失败模式对后续同步更有参照性。

## 步骤 1：同步上游 tag

```bash
bash "$SKILL_DIR/scripts/sync.sh" <上游tag> <目标分支>
```

脚本会自动：前置检查（工作区干净、无进行中合并）→ 确保 upstream remote → fetch 目标分支与上游 tag → 基于 `origin/<目标分支>` 创建 `sync/<tag>` 分支 → merge 上游 tag → 对齐 submodule。按结果处理：

- **MERGED（退出码 0）**：合并成功。git 自动合并成功不代表 alauda 定制完好（上游可能改写了相邻代码），继续步骤 2 之前先验证 5 个定制点仍在：

  ```bash
  grep -n 'ARG base_image\|ARG debug_image' cmd/jaeger/Dockerfile cmd/es-rollover/Dockerfile cmd/es-index-cleaner/Dockerfile
  grep -n '_build-a-binary-es' scripts/makefiles/BuildBinaries.mk
  grep -n 'LD_EXTRAFLAGS' scripts/makefiles/BuildInfo.mk
  ```

  应看到：3 个 Dockerfile 均有 `=scratch` 默认值、BuildBinaries.mk 的 es-* 目标走 `_build-a-binary-*` 规则、BuildInfo.mk 的 ldflags 含 `$(LD_EXTRAFLAGS)`。缺失则按背景知识恢复并记录。
- **UP_TO_DATE（退出码 0）**：目标分支已包含该 tag，无需同步，直接向用户汇报并结束。
- **CONFLICT（退出码 2）**：合并冲突，需要你逐文件解决。原则：
  - 背景知识里列出的 5 个被 alauda 定制过的上游文件：保留 alauda 改动的同时合入上游新变化，通常是"都要"而不是二选一；
  - 其余文件的冲突大多直接取上游内容（fork 未定制它们），但要看上下文确认；
  - submodule（idl/jaeger-ui）指针冲突取上游 tag 记录的 commit；
  - 只要有一个冲突拿不准，停下来向用户提问（附冲突片段和你的倾向方案）；
  - 解决完 `git add <文件>` 后运行 `bash "$SKILL_DIR/scripts/finish-merge.sh"` 完成合并 commit 与 submodule 对齐（禁止 amend）；
  - 解决了哪些冲突、如何取舍，记录下来写进最终汇报。
- **其他失败（退出码 1）**：前置条件问题（工作区不干净、分支已存在、tag 不存在等），把报错原样告知用户并询问如何处理，不要擅自 stash 或删分支。

## 步骤 2：本地构建验证 3 个二进制

```bash
bash "$SKILL_DIR/scripts/build.sh" <上游tag>
```

依次构建 jaeger（含 UI）、es-rollover、es-index-cleaner 并用 `--help` 验证，构建方式与 CI 一致（`SKIP_DEBUG_BINARIES=1`、`GIT_CLOSEST_TAG=<tag>`）。

- **BUILD_OK（退出码 0）**：继续步骤 3。
- **BUILD_FAILED（退出码 2）**：读脚本列出的失败日志，分析并修复。常见方向：上游构建体系变动波及 alauda 定制的 `.mk` 文件（对照上游本次 tag 的改动调整）；`go.mod` 要求更高的 Go 版本（本地与 CI 工具链需同步升级）；rebuild-ui 下载 UI 资产失败（确认 jaeger-ui submodule 是否位于上游 release tag、网络是否可达；否则需要 node 环境完整构建）。属同步范畴的修复直接改并创建新 commit；修完重跑 build.sh 直到通过。

## 步骤 3：更新集群插件版本

```bash
bash "$SKILL_DIR/scripts/update-chart.sh" <上游tag> <ACP产品版本>
```

调用 chart 自带的 `hack/update-version.sh`：`Chart.yaml` 的 `appVersion` 更新为上游版本、`version` 更新为 ACP 产品版本，并联动更新 `module-plugin.yaml` 与 `values.yaml` 的 jaeger 镜像 tag，然后自动提交一个 commit。oauth2-proxy 的 tag 独立维护，本步骤不会也不应改动。

## 步骤 4：创建 PR

先把 PR 描述写进临时文件（scratchpad 下，如 `pr-body.md`）：同步分支与合入提交数、冲突文件及解决方式、3 个二进制构建结果、版本变更（appVersion / version / 镜像 tag），结尾加一行 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <上游tag> <目标分支> <PR正文文件>
```

脚本会 push 同步分支、把上游 tag 推到 fork（fork 约定携带上游 release tag，供 git describe 版本推导；fork 的构建 workflow 只被 `plugin-v*-r*` tag 触发，推上游版本 tag 不会触发构建），并创建/复用 PR（显式 `--repo alauda-mesh/jaeger`），输出 `PR_NUMBER=` 与 `PR_URL=`。若报 gh 未认证，提示用户执行 `! gh auth login` 后重试。

## 步骤 5：监控 PR 流水线

`Alauda Build Jaeger` 全流程（二进制 → 多架构镜像 → chart）通常需要 10～30 分钟。**不要用 Bash 后台方式长驻运行 watch-pipeline.sh**——实测含 `sleep` 轮询的长驻后台 Bash 会被执行环境无预警终止（v2.20.0 同步时连续两次在约 1 分钟后被杀，输出戛然而止且无退出码）。正确姿势分两步：

1. 用 **Monitor 工具**（persistent: true）跑轻量轮询等收敛，每 60s 查一次，仅状态变化时发事件，Alauda run completed 且全部 checks 无 pending（总数 ≥10，上游 CI 分阶段注册）时输出 `CONVERGED` 并退出。注意事件要覆盖成功与失败所有终态；
2. 收到收敛事件后**前台**运行 watch-pipeline.sh 做结果解析（此时一切已 completed，脚本一次跑完不长驻）：

```bash
bash "$SKILL_DIR/scripts/watch-pipeline.sh" <PR编号>
```

脚本先确认 `Alauda Build Jaeger` 结论（成功时输出本次 PR 构建的镜像与 chart 地址），再核对全部 PR checks（总超时 60 分钟，环境变量 `WATCH_TIMEOUT_MINUTES` 可调）。按退出结果处理：

- **PIPELINE_SUCCESS（退出码 0）**：把输出的镜像/chart 地址与 WARN 项纳入最终汇报。
- **PIPELINE_FAILED（退出码 2）**：输出已附失败 job 与日志摘要，分析失败原因：
  - `Alauda Build Jaeger` 失败：二进制构建失败通常与本地构建同因；镜像构建失败多与 Dockerfile 的冲突处理有关；chart 相关失败检查 `hack/update-version.sh` 依赖的标记行是否被合并破坏；
  - 上游 CI 失败（lint / 单测 / e2e）：多为合并后的真实回归或冲突解决引入的问题，用 `gh run view <run-id> --repo alauda-mesh/jaeger --log-failed` 定位；self-hosted runner 的日志混有大量安全代理（harden-runner/armour）噪音，先用 `gh run view --job <job-id>` 看步骤级结论定位失败 step，再对日志 grep 关键词，比通读日志高效得多；
  - 已见过的两类失败模式（v2.20.0 同步）：① 上游 lint 规则扩大扫描范围波及 alauda 自有文件——如 lint-license 把 alauda 的 yaml 纳入检查，本地跑对应 lint 目标（如 `make lint-license`，updateLicense.py 会就地补头）修复后提交；② 上游 CI 步骤对 self-hosted runner 环境有新要求或 runner 组件损坏——如上游 setup-node.js 改用 pnpm 后踩中 runner 自带 npm 损坏，此类优先考虑"该步骤对 alauda 构建是否必要"（jaeger-ui 位于 release tag 时 UI 资产走 curl 下载，Node.js 完全不需要，直接从 alauda workflow 删除该步骤），实在需要的环境组件才提示用户修 runner；
  - 判断属同步引入的问题：修复 → 新 commit（带 `-s`）→ `git push origin HEAD`（每次 push 都会重触发全部流水线，修复要攒成一批一次推）→ 重新后台运行 watch-pipeline.sh；拿不准的修复先向用户提问。
- **PIPELINE_TIMEOUT（退出码 3）**：告知用户流水线仍在运行，附链接；之后可重跑 watch-pipeline.sh 继续等待。
- **PIPELINE_NOT_FOUND（退出码 4）**：按脚本提示排查（runner 离线、paths 未触发等），如实告知用户。

## 步骤 6：最终汇报

用清晰的列表向用户汇报（这是用户 review 的依据）：

1. 同步分支、PR 链接、合入的上游提交数；
2. 冲突文件清单及每个文件的解决方式（无冲突则写明"无冲突"）；
3. 3 个二进制的本地构建结果（含修复过的问题）；
4. 版本变更：`appVersion` → 新上游版本、`version` → ACP 产品版本、jaeger 镜像 tag；
5. 流水线结果：成功时列出镜像与 chart 地址；WARN 的已知环境失败项如实列出；
6. **固定提醒**：oauth2-proxy 镜像需人工按 `alauda/README.md` 的「Oauth2 Proxy 镜像更新」章节独立同步（regctl 本地过滤架构 + 补 label 后一次性推送最终 tag），并更新 `values.yaml` 中 `# oauth2-proxy-tag` 标记行；若上游无新版本或安全修复需求，可保持现状。

可顺带提一句：PR 合并后如需正式发版，按 `alauda/README.md` Release 章节创建 `plugin-<ACP产品版本>` tag（如 `plugin-v2.2.0-r0`）触发发布构建。

不要自行 merge PR，等用户 review 与合并。
