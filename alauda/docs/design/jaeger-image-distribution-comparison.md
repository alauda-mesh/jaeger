# Jaeger 镜像分发方案设计对比

> 本文对比 Jaeger 镜像在 ACP（Alauda Container Platform）上的两种分发/发版设计：
> **方案一**——随 `Alauda Build of OpenTelemetry v2` 插件一起分发（**当前现状**）；
> **方案二**——将 Jaeger 镜像独立封装为 `Alauda Build of Jaeger v2` ACP 集群插件。
>
> 目的：厘清两种设计的机制差异与优缺点，为后续是否拆分 Jaeger 插件提供决策依据。

---

## 1. 背景

`./jaeger/` 仓库（Alauda 的 Jaeger 发行版）在打 `vx.y.z-rn`（如 `v2.16.0-r0`）tag 后，由 CI 构建并推送三个多架构镜像（`linux/amd64`、`linux/arm64`）：

| 组件 | 镜像地址 | 说明 |
| --- | --- | --- |
| jaeger | `build-harbor.alauda.cn/asm/jaeger` | Jaeger 主服务（含 UI） |
| es-rollover | `build-harbor.alauda.cn/asm/jaeger-es-rollover` | ES 索引滚动工具 |
| es-index-cleaner | `build-harbor.alauda.cn/asm/jaeger-es-index-cleaner` | ES 索引清理工具 |

`jaeger/` 仓库本身**只负责构建镜像**，并不负责"把镜像送进客户集群"。真正决定这些镜像如何随产品交付、如何同步到 ACP 集群内置镜像仓库、以何种版本节奏发布的，是下游的封装/发版设计。本文对比的正是这一层。

> 关键事实：`opentelemetry-operator` 仓库中，只有 `RELATED_IMAGE_COLLECTOR` 被作为 manager 容器的环境变量消费（即 Operator 运行时会用它拉起 Collector）。Jaeger 三个镜像**仅出现在 CSV 的顶层 `relatedImages` 列表中**，Operator 自身并不部署 Jaeger。也就是说，Jaeger 镜像是"搭车"进入 Operator bundle 的镜像清单，主要服务于**离线镜像同步（mirror）与 bundle 镜像清单声明**，而非由 Operator 拉起。

---

## 2. 方案一：随 OpenTelemetry Operator v2 插件分发（现状）

### 2.1 机制

OTel Operator v2 以 **OLM Operator**（`operators.coreos.com/v1alpha1`，CSV + bundle）形态交付。Jaeger 镜像通过 OLM 原生的 `relatedImages` 机制，声明在 Operator 的 CSV 里：

- **`opentelemetry-operator/alauda/alauda-csv.yaml`**：作为 patch 模板，在 `relatedImages` 中声明 `component.jaeger`、`component.jaeger-es-rollover`、`component.jaeger-es-index-cleaner`，镜像 tag 用 `JAEGER-TAG-PLACEHOLDER` 占位（三个 Jaeger 镜像共用同一个 Jaeger tag）。
- **`opentelemetry-operator/hack/alauda-patch.sh`**：对社区版 bundle CSV 做后处理——合并 `alauda-csv.yaml` 的覆盖项、追加 manager 环境变量，并把 `OPENTELEMETRY-OPERATOR2-TAG` / `OPENTELEMETRY-COLLECTOR-TAG` / `JAEGER-TAG` / `OAUTH2-PROXY-TAG` 四个占位符替换为发版时传入的实际 tag。
- **`.github/workflows/alauda-release.yaml`**：单一的 `workflow_dispatch` 流水线，入参包含 `jaeger_tag`（如 `2.16.0-r2`）。流水线一次性完成：构建 Operator 镜像 → `make bundle` 生成 OLM bundle → `make alauda-patch` 注入 Jaeger 等 tag → 构建并推送 bundle 镜像 → 创建 GitHub Release `Alauda Build of OpenTelemetry vX`。

### 2.2 数据流

```
jaeger 仓库 ──打 tag──> CI 构建 jaeger / es-rollover / es-index-cleaner 镜像
                                          │（镜像已在 harbor，仅得到一个 tag 字符串）
                                          ▼
opentelemetry-operator 仓库:  alauda-release 流水线（手动填入 jaeger_tag）
   alauda-csv.yaml ──patch──> CSV.relatedImages 注入 Jaeger 镜像地址+tag
                                          ▼
                          单一 OLM bundle 镜像
                                          ▼
                ╔══════════════════════════════════════╗
                ║  插件：Alauda Build of OpenTelemetry v2 ║
                ║  （含 operator + collector + jaeger ×3 ║
                ║    + oauth2-proxy 的镜像清单）          ║
                ╚══════════════════════════════════════╝
```

### 2.3 发版结果

- **一个插件**：`Alauda Build of OpenTelemetry v2`。
- **一条流水线**：Jaeger 的版本以"入参"形式注入，Jaeger 不单独发版。
- 用户在 ACP 上**只需安装一个插件**即可同时获得 OTel 与 Jaeger 的镜像清单。

---

## 3. 方案二：独立封装为 Jaeger v2 ACP 集群插件

参考 `servicemesh2-docs/charts/mesh-v2-test-suite` 的模式，将 Jaeger 镜像列表封装成一个 **ACP 集群插件（ModulePlugin）**。构建规范见在线文档 [plugin-build-guide.md](https://github.com/alauda/cluster-plugin/blob/main/docs/plugin-build-guide.md)。

### 3.1 机制

以 Helm chart + `ModulePlugin` CR 的形式交付（与 OLM 是 ACP 上**两套不同的插件子系统**）：

- **`Chart.yaml`**：Helm chart 元信息（`type: application`）。
- **`module-plugin.yaml`**：`cluster.alauda.io/v1alpha1` 的 `ModulePlugin` 声明，定义插件身份、展示名、分类、`appReleases[].chartVersions[].version` 等。
- **`values.yaml` 的 `global.images`**：声明随插件下发的镜像清单（Jaeger 场景即 `jaeger` / `jaeger-es-rollover` / `jaeger-es-index-cleaner`）。`repository` 必须是**不含 registry 前缀**的相对路径，外加 `tag` / `support_arm` / `thirdparty`。
- **`scripts/plugin-config.yaml`**：`valuesTemplates` 在安装时用 `<< .RegistryAddress >>` 把 `global.registry.address` 重写为**当前集群的内置镜像仓库地址**。
- **`templates/_helpers.tpl` + 占位 ConfigMap**：用 helper 把镜像拼成完整可拉取地址，安装后通过 ConfigMap（`data.registry` / `data.images`）暴露给业务工作负载引用。
- **打包上架**：`helm package`/`helm push` 推 chart 到 OCI 仓库，再用 `violet create`/`package`/`push` 把 chart 与镜像打成插件包并上架到 ACP。安装时镜像被同步进集群内置仓库。
- **版本管理**：chart 版本号需在 `Chart.yaml` 与 `module-plugin.yaml` 两处保持一致（`hack/update-version.sh` 一键同步）。

### 3.2 数据流

```
jaeger 仓库 ──打 tag──> CI 构建 jaeger / es-rollover / es-index-cleaner 镜像
                                          │
                                          ▼
        Jaeger 插件 chart:  values.yaml.global.images 列出三个镜像
            helm package/push + violet create/package/push
                                          ▼
                ╔══════════════════════════╗      ╔══════════════════════════════════╗
                ║ 插件：Alauda Build of      ║      ║ 插件：Alauda Build of               ║
                ║       Jaeger v2           ║      ║       OpenTelemetry v2（不含 jaeger）║
                ║ （jaeger ×3 镜像清单）      ║      ║ （operator + collector + oauth2）   ║
                ╚══════════════════════════╝      ╚══════════════════════════════════╝
                          │ 安装时同步到集群内置镜像仓库
                          ▼
                ConfigMap 暴露完整可拉取地址供业务引用
```

### 3.3 发版结果

- **两个插件**：`Alauda Build of OpenTelemetry v2`（去掉 Jaeger）+ `Alauda Build of Jaeger v2`。
- **两条发版流程**：各自独立的版本号与打包/上架流水线。
- 用户需要分别安装两个插件，才能获得完整的"采集 + 存储/查询/UI"追踪能力。

---

## 4. 维度对比总览

| 维度 | 方案一：随 OTel Operator v2 插件 | 方案二：独立 Jaeger v2 集群插件 |
| --- | --- | --- |
| 分发载体 | OLM Operator Bundle / CSV `relatedImages` | ACP `ModulePlugin`（Helm chart + `global.images`） |
| 插件数量 | **1 个** | **2 个** |
| 发版流水线 | 1 条（otel-operator `alauda-release`） | 2 条（otel + jaeger 各一） |
| Jaeger 版本载体 | Operator 流水线的入参 `jaeger_tag` | Jaeger 插件自身的 chart 版本号 |
| 镜像进入集群的方式 | OLM `relatedImages`（mirror / bundle 镜像清单） | `global.images` 安装时同步到内置仓库，ConfigMap 暴露地址 |
| 版本耦合度 | **强**：Jaeger 随 Operator 一起发 | **弱**：各自独立发版 |
| 独立复用 | 否，必须随 Operator 安装 | 是，可被任意产品/集群单独安装 |
| 兼容性管理 | 一次发版即锁定组合，无组合矩阵 | 需管理/测试 Operator × Jaeger 版本组合矩阵 |
| 依赖约束 | 同包交付，天然共同可用 | 无声明式依赖，靠文档/人工保证组合正确 |
| 新增维护对象 | 仅 `alauda-csv.yaml` + patch 脚本 | 新增并长期维护 chart + ModulePlugin + violet 流程 |
| 用户安装步骤 | 装 1 个插件 | 装 2 个插件（需说明顺序/依赖） |
| Owner / 主导仓库 | `opentelemetry-operator` 仓库 | `jaeger` 仓库可自主掌控 |
| 与现有资产的契合 | 即现状，零额外成本 | 复用 `mesh-v2-test-suite` 的成熟模式 |
| CVE / 热修响应 | 必须走整条 Operator 发版 | 可单独快速补丁发布 |

---

## 5. 方案一优缺点

### 优点

1. **发版与安装最简**：只发一个插件、跑一条流水线，用户只装一个插件。Jaeger 版本作为流水线入参注入，无需为 Jaeger 单独发版。
2. **版本一致性强、无组合矩阵**：Operator、Collector、Jaeger、OAuth2-Proxy 的版本组合在**同一次发版**中确定并整体验证，从源头杜绝版本漂移与"装到不兼容组合"的问题。
3. **复用 OLM 原生机制、离线场景成熟**：`relatedImages` 是 OperatorHub/OLM 标准的伴随镜像声明，离线镜像同步（mirror）工具链天然识别，air-gap 场景路径成熟，无需自行设计镜像同步逻辑。
4. **维护面最小**：不需要新建并长期维护独立的 chart 仓库、`module-plugin.yaml`、`plugin-config.yaml` 和 violet 打包/上架流程。改动集中在一个 `alauda-csv.yaml` 加一个 patch 脚本。
5. **单一事实来源**：所有可观测组件镜像集中在一个 CSV 的 `relatedImages` 中，便于审计与离线清单导出。

### 缺点

1. **强耦合，发版被绑死**：Jaeger 的任何发布（哪怕只是修一个 CVE）都必须搭载 OTel Operator 走完整条发版流水线、产出新的 Operator bundle 版本；反之 Operator 发版也被动带上 Jaeger。两者无法独立演进。
2. **版本语义混淆**：插件版本号是 Operator 的版本，Jaeger 的升级只体现在 `relatedImages` 的 tag 上，不反映在插件大版本里，用户难以单独感知"Jaeger 升级了"。
3. **无法被其他产品独立复用**：若 ASM、独立 Tracing 方案等只需要 Jaeger 镜像而不需要 OTel Operator，没有单独安装 Jaeger 的途径，只能整包安装 Operator 插件。
4. **跨仓库职责边界模糊**：Jaeger 由 `jaeger` 仓库构建，但其"发布动作"和版本节奏由 `opentelemetry-operator` 仓库的流水线控制，每次发版需要把 Jaeger tag **手动填入** Operator 流水线，存在跨团队协调成本与填错风险。
5. **镜像落地语义不够显式**：`relatedImages` 主要面向 mirror / bundle 清单；这些镜像是否、以及以何种地址被同步到集群内置仓库并供业务引用，取决于平台对 OLM `relatedImages` 的集成实现，不如方案二 `global.images` + registry 重写 + ConfigMap 暴露地址那样显式、可控。

---

## 6. 方案二优缺点

### 优点

1. **解耦、可独立演进**：Jaeger 拥有独立的发版流程与版本号，能不受 Operator 节奏约束地单独发布；CVE / 热修可快速单独出包。
2. **版本与职责清晰**：`Alauda Build of Jaeger v2` 有自己的版本语义和明确 Owner（`jaeger` 仓库/团队），升级可被用户直观感知。
3. **可被独立复用**：任何需要 Jaeger 镜像的产品或集群都能单独安装该插件，不绑定 OTel Operator，扩大了 Jaeger 发行版的适用面。
4. **镜像分发语义显式、可控**：`ModulePlugin` 的 `global.images` + `valuesTemplates` registry 重写是 ACP 原生、成熟的"镜像随插件下发到内置仓库"机制；安装后通过 ConfigMap 暴露**完整可拉取地址**，业务引用路径明确。
5. **按需选择、减少冗余**：只需要 Jaeger 的场景不必安装 OTel Operator，避免下发用不到的组件镜像。
6. **复用既有模式与经验**：`servicemesh2-docs/charts/mesh-v2-test-suite` 已验证了"chart 模板 + ModulePlugin + violet 打包上架"的完整链路，团队有可直接套用的模板与流程经验。

### 缺点

1. **发版与运维成本翻倍**：要发两个插件、维护两套版本号（且 chart 版本需在 `Chart.yaml` 与 `module-plugin.yaml` 两处保持同步）、跑两条打包/上架流程。
2. **引入版本组合矩阵**：Operator 与 Jaeger 各自演进后，需要管理与测试两者的兼容性组合；用户存在装到不兼容组合的风险。
3. **缺少声明式依赖、安装步骤更多**：OLM 与 ModulePlugin 分属两套子系统，"装了 Jaeger 不代表装了 Operator"无法用 OLM dependency 那样声明式约束，只能靠文档/人工保证；用户需安装两个插件并理解其先后依赖（如 Jaeger 需先于上报追踪的示例服务就绪）。
4. **新增长期维护对象**：需要在 `jaeger`（或文档/charts）仓库新建并长期维护一套 chart + `ModulePlugin` + `plugin-config.yaml` + violet 流水线，有初期投入与持续维护成本。
5. **需遵守 ModulePlugin 的打包约束**：所有镜像必须与主 chart 同一 registry domain；`global.images.<name>.repository` 不能含 registry 前缀，否则会被拼成错误的双域名地址（与 `mesh-v2-test-suite` 的约束一致）。
6. **离线/mirror 走 ACP 自有通道**：air-gap 场景不再依赖 OLM 标准 mirror 工具，而是走 ACP ModulePlugin 的同步机制。在 ACP 语境下这反而是原生路径，但与 OLM 工具链并存会带来一定认知/工具差异。

---

## 7. 适用场景与建议

两种方案没有绝对优劣，取舍取决于 **Jaeger 是否需要脱离 OTel Operator 独立存在**：

- **倾向方案一（维持现状）**，当：
  - Jaeger 在产品形态上**总是与 OTel Operator v2 捆绑交付**，没有"单独要 Jaeger"的诉求；
  - 团队更看重**发版/安装的简单性**与**版本组合的强一致性**；
  - 希望把离线镜像同步继续交给成熟的 OLM mirror 工具链；
  - 不希望新增一套 chart/插件的长期维护负担。

- **倾向方案二（拆分独立插件）**，当：
  - Jaeger 需要**独立的发布节奏**（如安全补丁要快速单发，不愿被 Operator 发版拖慢）；
  - Jaeger 镜像需要**被 OTel Operator 之外的产品复用**（ASM、独立 Tracing 等）；
  - 希望 Jaeger 有**清晰、用户可感知的独立版本语义与 Owner**；
  - 团队愿意承担两个插件的版本组合管理与维护成本，并已准备好复用 `mesh-v2-test-suite` 模式。

### 可选的折中思路

若既想要方案二的"独立 Jaeger 插件"、又不愿放弃方案一的离线完整性，可考虑**以 Jaeger v2 插件作为 Jaeger 镜像的事实来源与分发载体**，同时在 OTel Operator 的 `relatedImages` 中保留 Jaeger 条目仅用于离线 mirror 清单完整性。但这会造成**镜像清单两处维护**的冗余，且 OLM 与 ModulePlugin 跨子系统难以建立声明式依赖，收益有限——除非离线 mirror 的完整性是硬约束，否则不建议同时维护两套。

> 综合来看：**若短期内 Jaeger 不存在独立复用与独立发版的明确需求，维持方案一成本最低；一旦出现"Jaeger 要被独立消费"或"发版节奏需解耦"的驱动，再切换到方案二并复用 `mesh-v2-test-suite` 模式是更顺的演进路径。**

---

## 附录：关键文件索引

**方案一（现状）**

- `opentelemetry-operator/alauda/alauda-csv.yaml` —— CSV patch 模板，`relatedImages` 声明 Jaeger 镜像
- `opentelemetry-operator/hack/alauda-patch.sh` —— 注入 tag 占位符的后处理脚本
- `opentelemetry-operator/.github/workflows/alauda-release.yaml` —— 单一发版流水线（含 `jaeger_tag` 入参）
- `jaeger/alauda/README.md` —— Jaeger 镜像构建说明

**方案二（参考样板）**

- `servicemesh2-docs/charts/mesh-v2-test-suite/` —— ACP 集群插件参考实现
  - `module-plugin.yaml` / `Chart.yaml` —— 插件声明与 chart 元信息
  - `values.yaml`（`global.images`）—— 镜像清单
  - `scripts/plugin-config.yaml` —— `valuesTemplates` registry 重写
  - `templates/_helpers.tpl`、`templates/image-manifest-configmap.yaml` —— 镜像地址 helper 与暴露 ConfigMap
  - `hack/update-version.sh` —— chart 版本号同步
- [plugin-build-guide.md](https://github.com/alauda/cluster-plugin/blob/main/docs/plugin-build-guide.md) —— ACP 集群插件构建规范
