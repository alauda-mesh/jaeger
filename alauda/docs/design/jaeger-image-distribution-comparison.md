# Jaeger 镜像分发方案设计对比

> 本文对比 Jaeger 镜像在 ACP（Alauda Container Platform）上的两种分发/发版设计：
> **方案一**——随 `Alauda Build of OpenTelemetry v2` 插件一起分发（**当前现状**）；
> **方案二**——将 Jaeger 镜像独立封装为 `Alauda Build of Jaeger v2` ACP 集群插件。
>
> 目的：厘清两种设计的机制差异与优缺点，为后续是否拆分 Jaeger 插件提供决策依据。

---

## 0. TL;DR

- 方案一：Jaeger 无独立插件，镜像放到 OTel 插件中（**现状**）。
  - 无 Jaeger 插件，OTel 插件包含 Jaeger 镜像，用户不好理解。
  - 调用链用户需要下载、上架和安装一个插件。
  - 因 Jaeger 部署依赖 OTel，无需维护这两者的矩阵关系。
  - 发版只需要发一个插件，但任意一个组件更新，都需要发 OTel 新版插件。
- 方案二：Jaeger 独立集群插件，镜像放到自己的插件中（**推荐**）。
  - 独立 Jaeger 插件用户好理解，AC 能搜索到 Jaeger。
  - 调用链用户需要下载、上架和安装两个插件。
  - 未来可能需要维护这两个插件的矩阵关系。
  - 两个插件可独立发版，独立更新。
  - 未来可扩展性强。

## 1. 背景

### 1.1 Jaeger 镜像如何构建

`./jaeger/` 仓库（Alauda 的 Jaeger 发行版）在打 `vx.y.z-rn`（如 `v2.16.0-r0`）tag 后，由 CI 构建并推送三个多架构镜像（`linux/amd64`、`linux/arm64`）：

| 组件             | 镜像地址                                             | 说明                                                                        |
| ---------------- | ---------------------------------------------------- | --------------------------------------------------------------------------- |
| jaeger           | `build-harbor.alauda.cn/asm/jaeger`                  | Jaeger 主服务（含 UI），基于 OpenTelemetry Collector 框架构建的自定义二进制 |
| es-rollover      | `build-harbor.alauda.cn/asm/jaeger-es-rollover`      | ES 索引滚动/初始化工具                                                      |
| es-index-cleaner | `build-harbor.alauda.cn/asm/jaeger-es-index-cleaner` | ES 索引清理工具                                                             |

`jaeger/` 仓库本身**只负责构建镜像**，并不负责"把镜像送进客户集群"，也不负责"部署 Jaeger 实例"。本文对比的，是镜像**如何随产品交付、如何进入 ACP 集群内置镜像仓库、以何种版本节奏发布**这一层设计。

### 1.2 关键架构事实：Jaeger 如何被部署（决定全文的核心前提）

> **Jaeger v2 实例是以 `OpenTelemetryCollector` 自定义资源的形式、由 `Alauda Build of OpenTelemetry v2` 插件中的 `opentelemetry-operator` 部署和管理的。**

参见 `distributed-tracing-docs/docs/en/installing/installing-distributed-tracing.mdx`：部署 Jaeger 时创建的并不是某个 `Jaeger` CRD，而是一个 `kind: OpenTelemetryCollector` 资源，把 `spec.image` 指向 Jaeger 镜像：

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector # 来自 opentelemetry-operator 的 CRD
metadata:
  name: jaeger
spec:
  image: "${JAEGER_IMAGE}" # 不是默认 collector 镜像，而是基于 Collector 框架构建的 Jaeger 二进制
  mode: deployment
  config: { ... jaeger_storage / jaeger_query 扩展 ... }
```

由此推出本文最重要的一条**非对称依赖关系**：

- **OTel 插件可以单独使用**——只部署 OpenTelemetry Collector、不部署 Jaeger，是合法形态。
- **Jaeger 无法脱离 OTel 插件存在**——`OpenTelemetryCollector` CRD 及其控制器都由 `opentelemetry-operator` 提供；没有该 operator，就无法部署 Jaeger 实例。因此 **Jaeger 在"部署"层面强依赖 OTel 插件**。
- **要区分"部署依赖"与"数据通路集成"**：Jaeger 实例自带 OTLP receiver（`4317/4318`），应用可以**直连 Jaeger** 上报；也可以在前面再放一个 OpenTelemetry Collector 做汇聚再转发给 Jaeger。是否集成 Collector 是**可选的使用场景**；而由 operator 完成的**部署，是必须的依赖**。本文讨论的依赖均指后者。

> 进一步地，现状部署文档**直接从 operator 的 CSV `relatedImages` 读取 Jaeger 镜像地址**再填入 `OpenTelemetryCollector`：
>
> ```bash
> JAEGER_RELATED_IMAGES=$(kubectl get csv -n opentelemetry-operator2 ... -o jsonpath='{.spec.relatedImages}')
> export JAEGER_IMAGE=$(echo "$JAEGER_RELATED_IMAGES" | jq -r '.[]|select(.name=="component.jaeger").image')
> export JAEGER_ES_ROLLOVER_IMAGE=$(... select(.name=="component.jaeger-es-rollover") ...)
> export JOAUTH2_PROXY_IMAGE=$(... select(.name=="component.oauth2-proxy") ...)
> ```
>
> 也就是说，在方案一中 `relatedImages` **不只是离线 mirror 清单，更是部署时取用镜像地址的事实来源**——部署 Jaeger 用的镜像与部署它的 operator，本就同源于同一个 CSV。

---

## 2. 方案一：随 OpenTelemetry Operator v2 插件分发（现状）

### 2.1 机制

OTel Operator v2 以 **OLM Operator**（`operators.coreos.com/v1alpha1`，CSV + bundle）形态交付。Jaeger 镜像通过 OLM 原生的 `relatedImages` 机制声明在 Operator 的 CSV 里：

- **`opentelemetry-operator/alauda/alauda-csv.yaml`**：作为 patch 模板，在 `relatedImages` 中声明 `component.jaeger`、`component.jaeger-es-rollover`、`component.jaeger-es-index-cleaner`，镜像 tag 用 `JAEGER-TAG-PLACEHOLDER` 占位（三个 Jaeger 镜像共用同一个 Jaeger tag）。
- **`opentelemetry-operator/hack/alauda-patch.sh`**：对社区版 bundle CSV 做后处理——合并 `alauda-csv.yaml` 的覆盖项、追加 manager 环境变量，并把 `OPENTELEMETRY-OPERATOR2-TAG` / `OPENTELEMETRY-COLLECTOR-TAG` / `JAEGER-TAG` / `OAUTH2-PROXY-TAG` 四个占位符替换为发版时传入的实际 tag。
- **`.github/workflows/alauda-release.yaml`**：单一的 `workflow_dispatch` 流水线，入参包含 `jaeger_tag`（如 `2.16.0-r2`）。一次性完成：构建 Operator 镜像 → `make bundle` 生成 OLM bundle → `make alauda-patch` 注入 Jaeger 等 tag → 构建并推送 bundle 镜像 → 创建 GitHub Release `Alauda Build of OpenTelemetry vX`。

部署阶段：管理员按文档从该 CSV 的 `relatedImages` 取出 `JAEGER_IMAGE` 等地址，填入 `OpenTelemetryCollector` CR 的 `spec.image`，由 operator 据此拉起 Jaeger 实例；`es-rollover` 作为一次性 `Job`（init 索引）、`oauth2-proxy` 作为 Jaeger UI 的认证 sidecar，镜像同样取自 `relatedImages`。

### 2.2 数据流

```
jaeger 仓库 ──打 tag──> CI 构建 jaeger / es-rollover / es-index-cleaner 镜像
                                          │（得到一个 tag 字符串）
                                          ▼
opentelemetry-operator 仓库:  alauda-release 流水线（手动填入 jaeger_tag）
   alauda-csv.yaml ──patch──> CSV.relatedImages 注入 Jaeger 镜像地址 + tag
                                          ▼
                          单一 OLM bundle 镜像
                                          ▼
                ╔═══════════════════════════════════════╗
                ║  插件：Alauda Build of OpenTelemetry v2  ║
                ║  = operator（部署 Jaeger 的控制器）       ║
                ║   + relatedImages（jaeger ×3 / collector ║
                ║     / oauth2-proxy 的镜像地址清单）       ║
                ╚═══════════════════════════════════════╝
                                          │ 部署时：从 CSV.relatedImages 取 JAEGER_IMAGE
                                          ▼
                operator 据 OpenTelemetryCollector CR(spec.image=JAEGER_IMAGE) 拉起 Jaeger
```

### 2.3 发版结果

- **一个插件**：`Alauda Build of OpenTelemetry v2`。
- **一条流水线**：Jaeger 版本以"入参"形式注入，Jaeger 不单独发版。
- 用户在 ACP 上**只装一个插件**，即同时获得"部署 Jaeger 的 operator"与"Jaeger 镜像地址"，二者同源同版本。

---

## 3. 方案二：独立封装为 Jaeger v2 ACP 集群插件

参考 `servicemesh2-docs/charts/mesh-v2-test-suite` 的模式，将 Jaeger 镜像列表封装成一个 **ACP 集群插件（ModulePlugin）**。构建规范见 [plugin-build-guide.md](https://github.com/alauda/cluster-plugin/blob/main/docs/plugin-build-guide.md)。

### 3.1 机制

以 Helm chart + `ModulePlugin` CR 的形式交付（与 OLM 在 ACP 上是**两套不同的插件子系统**）：

- **`Chart.yaml`** / **`module-plugin.yaml`**：chart 元信息与 `cluster.alauda.io/v1alpha1` 的 `ModulePlugin` 声明（插件身份、展示名、版本等）。
- **`values.yaml` 的 `global.images`**：声明随插件下发的镜像清单——Jaeger 场景应包含 `jaeger` / `jaeger-es-rollover` / `jaeger-es-index-cleaner`，**以及 `oauth2-proxy`**。`oauth2-proxy` 是 Jaeger UI 的认证 sidecar（部署时作为 Jaeger 实例 `OpenTelemetryCollector` 的 `additionalContainers` 注入，为 Jaeger UI 对接 ACP 授权），功能上归属 Jaeger，**应随 Jaeger 插件下发**；它是上游同步的第三方镜像（`thirdparty: true`），本身不由 `jaeger` 仓库构建，但这不影响它在打包归属上属于 Jaeger。`repository` 必须是**不含 registry 前缀**的相对路径。
- **`scripts/plugin-config.yaml`**：`valuesTemplates` 在安装时用 `<< .RegistryAddress >>` 把 registry 重写为**当前集群的内置镜像仓库地址**。
- **`templates/_helpers.tpl` + 占位 ConfigMap**：把镜像拼成完整可拉取地址，安装后通过 ConfigMap（`data.registry` / `data.images`）暴露给使用方引用。
- **打包上架**：`helm package`/`helm push` 推 chart 到 OCI，再用 `violet create`/`package`/`push` 把 chart 与镜像打成插件包上架 ACP；安装时镜像被同步进集群内置仓库。
- **版本管理**：chart 版本号需在 `Chart.yaml` 与 `module-plugin.yaml` 两处保持一致（`hack/update-version.sh` 一键同步）。

> **重要**：该插件只负责**分发镜像**，**不提供部署能力**（没有 CRD / 控制器）。要真正部署 Jaeger 实例，**仍然必须安装 OTel 插件**、由其 operator 通过 `OpenTelemetryCollector` 完成。因此本方案下用户需**同时安装两个插件**，且部署文档需改为从本插件的 ConfigMap（而非 operator CSV）取镜像地址。

### 3.2 数据流

```
jaeger 仓库 ──打 tag──> CI 构建 jaeger / es-rollover / es-index-cleaner 镜像
                                          ▼
        Jaeger 插件 chart:  values.yaml.global.images 列出镜像
            helm package/push + violet create/package/push
                                          ▼
    ╔══════════════════════════╗        ╔══════════════════════════════════════╗
    ║ 插件：Alauda Build of      ║        ║ 插件：Alauda Build of OpenTelemetry v2 ║
    ║       Jaeger v2           ║        ║ = operator（部署 Jaeger 的控制器）       ║
    ║ = jaeger×3 + oauth2-proxy ║        ║   + collector 镜像（不含 jaeger/oauth2）║
    ╚══════════════════════════╝        ╚══════════════════════════════════════╝
              │ 安装时同步镜像到内置仓库            │ 提供 OpenTelemetryCollector CRD + 控制器
              │ ConfigMap 暴露镜像地址             │
              └───────────────┬──────────────────┘
                              ▼  二者缺一不可，才能部署 Jaeger
            operator 据 OpenTelemetryCollector CR(spec.image=Jaeger 插件提供的镜像) 拉起 Jaeger
```

### 3.3 发版结果

- **两个插件**：`Alauda Build of OpenTelemetry v2`（仅 operator + collector 镜像）+ `Alauda Build of Jaeger v2`（`jaeger` ×3 **加 `oauth2-proxy`**，即部署 Jaeger 实例及其 UI 认证 sidecar 所需的全部镜像）。
- **两条发版流程**：各自独立的版本号与打包/上架流水线。
- 用户需**分别安装两个插件**才能部署 Jaeger；两个插件分属 OLM 与 ModulePlugin 两套子系统，依赖关系无法声明式表达。

---

## 4. 维度对比总览

| 维度                         | 方案一：随 OTel Operator v2 插件             | 方案二：独立 Jaeger v2 集群插件                    |
| ---------------------------- | -------------------------------------------- | -------------------------------------------------- |
| 分发载体                     | OLM Operator Bundle / CSV `relatedImages`    | ACP `ModulePlugin`（Helm chart + `global.images`） |
| 插件数量                     | **1 个**                                     | **2 个（缺一不可才能部署 Jaeger）**                |
| 部署 Jaeger 的硬依赖         | 同一插件内即满足（operator + 镜像同源）      | 仍需 OTel 插件；本插件只补充镜像                   |
| 发版流水线                   | 1 条（otel-operator `alauda-release`）       | 2 条（otel + jaeger 各一）                         |
| Jaeger 版本载体              | Operator 流水线入参 `jaeger_tag`             | Jaeger 插件自身 chart 版本号                       |
| 部署取镜像来源               | operator CSV `relatedImages`（与控制器同源） | Jaeger 插件安装后暴露的 ConfigMap                  |
| operator ↔ Jaeger 版本一致性 | **天然同源同版本、同发版同测试**             | 各自演进，需人工/文档保证组合可用                  |
| 镜像进入集群的方式           | OLM `relatedImages`（mirror + 部署取址）     | `global.images` 安装时同步到内置仓库               |
| 跨插件依赖约束               | 无需（本就一体）                             | **无法声明式表达**，靠文档约束                     |
| 独立发版 / 热修              | 否，须随 operator 重新发版                   | **是**，Jaeger 镜像可独立打补丁                    |
| 新增维护对象                 | 仅 `alauda-csv.yaml` + patch 脚本            | 新增 chart + ModulePlugin + violet 流程            |
| 用户安装步骤                 | 装 1 个插件                                  | 装 2 个插件（需说明依赖/顺序）                     |
| Owner / 主导仓库             | `opentelemetry-operator` 仓库                | `jaeger` 仓库可自主                                |
| 与现有资产的契合             | 即现状，零额外成本                           | 复用 `mesh-v2-test-suite` 模式                     |

---

## 5. 方案一优缺点

### 优点

1. **与部署架构天然契合（最关键）**：Jaeger 实例由 operator 通过 `OpenTelemetryCollector` 部署，而 operator 与 Jaeger 镜像引用同处一个 CSV，部署时直接从 `relatedImages` 取镜像地址。**"部署 Jaeger 的控制器"与"被部署的 Jaeger 镜像"同源、同版本、同一次发版同一次测试**，从结构上杜绝二者版本错配。
2. **依赖关系天然满足**：既然 Jaeger 部署本就强依赖 operator，把镜像与 operator 装在同一个插件里，意味着"装了 OTel 插件 = 具备部署 Jaeger 的全部要件"，不存在"有镜像但无 operator"或"有 operator 但镜像缺失/版本不符"的中间态。
3. **发版与安装最简**：只发一个插件、跑一条流水线，用户只装一个插件；Jaeger 版本作为入参注入，无需单独发版。
4. **版本组合强一致、无矩阵**：operator / collector / jaeger / oauth2-proxy 的版本组合在**同一次发版**中确定并整体验证，杜绝版本漂移。
5. **复用 OLM 原生机制**：`relatedImages` 既是离线镜像同步（mirror）清单、也是部署取镜像的来源，air-gap 链路成熟，无需自研镜像同步。
6. **维护面最小**：无需新建并长期维护独立 chart 仓库、`module-plugin.yaml`、`plugin-config.yaml` 与 violet 流程。

### 缺点

1. **强耦合，发版被绑死**：Jaeger 镜像的任何发布（哪怕只是修一个 CVE）都必须**重跑 OTel Operator 整条发版流水线**、产出新的 bundle 版本；无法独立打补丁。
2. **版本语义混淆**：插件版本号是 operator 的版本，Jaeger 的升级只体现在 `relatedImages` 的 tag 上，不反映在插件大版本里，用户难以单独感知"Jaeger 升级了"。
3. **跨仓库手动协调**：Jaeger 由 `jaeger` 仓库构建，但其"发布动作"由 `opentelemetry-operator` 仓库的流水线控制，每次发版需把 Jaeger tag **手动填入** operator 流水线，存在协调成本与填错风险。

> 注：方案一**不存在**"无法被独立复用"这一缺点——因为 Jaeger 部署本就必须依赖 operator，不存在脱离 operator 单独使用 Jaeger 镜像的合理场景（见 §1.2）。这恰恰是方案一与架构契合之处。

---

## 6. 方案二优缺点

### 优点

1. **独立发版节奏 / 快速热修（最主要、且依然成立的优势）**：Jaeger 镜像可独立打补丁、独立出包，**不必为一个 Jaeger 的 CVE 重新发布整个 operator**。这是方案二相较方案一唯一实质性的核心收益。
2. **清晰的版本语义与 Owner**：`Alauda Build of Jaeger v2` 有自己的插件版本号与 `jaeger` 仓库 Owner，升级对用户可感知、职责边界清晰。
3. **显式的镜像分发语义**：`global.images` + registry 重写 + ConfigMap 暴露地址，是 ACP 原生、成熟的"镜像随插件下发到内置仓库"机制；安装后 Jaeger 镜像同步到内置仓库、引用路径明确。
4. **可顺带下发开箱即用资产**：如同 `mesh-v2-test-suite`，可在插件里附带 Jaeger 部署用的示例 `OpenTelemetryCollector` / `Instrumentation` / 监控面板等 manifest，提升落地体验（但**部署本身仍依赖 operator**）。
5. **复用既有模式与经验**：团队已有 `mesh-v2-test-suite` 验证过的 chart 模板 + ModulePlugin + violet 打包上架链路，可直接套用。

### 缺点

1. **"独立复用"并不成立——拆分不解耦反增协调**：很多人期望"独立插件 = Jaeger 可独立使用"，但 §1.2 已说明，**Jaeger 部署永远离不开 OTel 插件的 operator**。拆分后并没有让 Jaeger 变得可独立部署，反而要求用户**同时安装两个插件**，且 OLM 与 ModulePlugin 两套子系统之间**无法声明式表达"Jaeger 插件依赖 OTel 插件"**，只能靠文档约束，更易漏装/装错。
2. **operator ↔ Jaeger 版本一致性风险（关键）**：Jaeger v2 是基于 OpenTelemetry Collector 框架构建的二进制，而部署它的 operator 也对所管理的 `OpenTelemetryCollector`（CRD schema、config 格式、feature gate）有版本预期。两者拆开独立演进后，需要额外维护并测试"operator 版本 × Jaeger 镜像版本"的**兼容矩阵**；方案一里它们同源同版本，方案二把这份一致性责任甩给了人和文档。
3. **发版/运维成本翻倍**：要发两个插件、维护两套版本号（chart 版本还需在两个文件间同步）、跑两条打包/上架流程。
4. **用户安装步骤增多**：要装两个插件、并理解其依赖与先后关系，体验更繁琐。
5. **新增长期维护对象**：需在 `jaeger`（或文档/charts）仓库新建并长期维护 chart + `ModulePlugin` + `plugin-config.yaml` + violet 流水线。
6. **需遵守 ModulePlugin 打包约束**：所有镜像须与主 chart 同一 registry domain；`repository` 不能含 registry 前缀，否则拼出错误的双域名地址（与 `mesh-v2-test-suite` 约束一致）。
7. **需改造现有部署文档**：现状文档从 operator CSV 的 `relatedImages` 取 `JAEGER_IMAGE`，方案二下要改为从 Jaeger 插件的 ConfigMap 取镜像地址。

---

## 7. 适用场景与建议

- **方案一**：
  - Jaeger 实例只能由 OTel 插件的 operator 通过 `OpenTelemetryCollector` 部署，**不存在脱离 OTel 插件的独立 Jaeger 使用场景**——拆分插件并不能带来"独立可用"，反而增加双插件协调；
  - Jaeger 镜像与部署它的 operator 同源于一个 CSV，**版本一致性由结构保证**；而 Jaeger v2 基于 Collector 框架，与 operator 的版本耦合恰恰需要这种"同发版同测试"；
  - 发版/安装最简，离线 mirror 走成熟的 OLM 链路，维护面最小。

- **方案二**：
  - 插件独立，发版时更清晰，用户能够在 AC 搜索到 Jaeger。
  - Jaeger 镜像需要**显著快于 operator 的独立发版/热修节奏**（如安全补丁要求脱离 operator 发版周期快速单发），且团队愿意承担由此带来的 operator×Jaeger 兼容矩阵管理成本；
  - 或希望未来借独立插件**顺带下发一套开箱即用的 Jaeger 部署/示例/面板资产**，把落地体验产品化。

---

## 附录：关键文件索引

**架构依据**

- `distributed-tracing-docs/docs/en/installing/installing-distributed-tracing.mdx` —— Jaeger v2 以 `OpenTelemetryCollector`（`spec.image=JAEGER_IMAGE`）部署、镜像取自 operator CSV `relatedImages` 的完整流程

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
