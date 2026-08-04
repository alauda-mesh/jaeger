# jaeger-cluster-plugin

Alauda Build of Jaeger v2 —— 一个仅用于分发镜像的 ACP 集群插件。

## 插件作用

将 Alauda Distributed Tracing（调用链）所需的容器镜像打包随插件下发。用户在 ACP 上安装本插件后，这些镜像会被同步到平台内置镜像仓库，安装调用链组件时可直接引用，无需再从外部公网拉取。

本插件**不部署任何工作负载**，安装时只在 `cpaas-system` 命名空间下创建一个 ConfigMap：

- `jaeger-cluster-plugin-manifest`：声明插件已安装，并提供镜像地址与版本信息，供安装调用链的文档步骤读取。

## 包含的镜像

镜像清单维护在 [`values.yaml`](./values.yaml) 的 `global.images` 字段。当前版本包含：

| 名称                    | 仓库路径                       | 版本               | 说明                    |
| ----------------------- | ------------------------------ | ------------------ | ----------------------- |
| jaeger                  | `asm/jaeger`                   | `2.16.0-2.1.0-r0`  | Jaeger 主服务（含 UI）  |
| jaeger-es-rollover      | `asm/jaeger-es-rollover`       | `2.16.0-2.1.0-r0`  | ES 索引滚动工具         |
| jaeger-es-index-cleaner | `asm/jaeger-es-index-cleaner`  | `2.16.0-2.1.0-r0`  | ES 索引清理工具         |
| oauth2-proxy            | `asm/oauth2-proxy`             | `v7.15.1-r0`       | Jaeger UI 认证代理      |

镜像源 registry 由 `global.registry.address` 配置，默认 `build-harbor.alauda.cn`。

## 版本模型

插件采用两条独立的版本轴：

- **集群插件版本**（chart 版本，如 `v2.1.0-r0`）：插件自身的发版节奏，维护在 [`Chart.yaml`](./Chart.yaml) 的 `version` 字段，正式发布由 git tag `plugin-<版本>`（如 `plugin-v2.1.0-r0`）驱动。
- **Jaeger 版本**（如 `2.16.0`）：与上游开源版本保持同步，维护在 [`Chart.yaml`](./Chart.yaml) 的 `appVersion` 字段，同步上游代码时人工更新。

3 个 Jaeger 镜像的 tag 由两者拼接为 `<Jaeger 版本>-<插件版本去 v 前缀>`（如 `2.16.0-2.1.0-r0`），与 chart 版本一一对应、每次插件发版均唯一，由 CI 或 [`hack/update-version.sh`](./hack/update-version.sh) 统一更新；oauth2-proxy 从上游同步、版本独立维护，同步方式见 [alauda/README.md](../README.md)。

## 目录结构

```
jaeger-cluster-plugin/
├── Chart.yaml                           Helm chart 元信息（含 OCI provenance 注解）
├── README.md                            本文件
├── module-plugin.yaml                   ACP 插件声明（ModulePlugin CR）
├── values.yaml                          镜像清单及全局变量
├── hack/
│   └── update-version.sh                版本更新脚本（chart 版本 + Jaeger 镜像 tag）
├── scripts/
│   └── plugin-config.yaml               插件配置（无可调参数的最小版本）
└── templates/
    ├── _helpers.tpl                     镜像 helper：按名拼出完整镜像地址
    └── image-manifest-configmap.yaml    镜像清单 ConfigMap
```

## ConfigMap 字段说明

插件安装完成后，可通过以下方式确认：

```bash
kubectl get configmap jaeger-cluster-plugin-manifest -n cpaas-system -o yaml
```

ConfigMap 的 `data` 字段（内容均为英文）：

- `version`：Alauda Build of Jaeger v2 集群插件版本（chart 版本）。
- `jaeger-version`：上游 Jaeger 发行版版本。
- `registry`：所有打包镜像统一使用的镜像仓库地址（由 `scripts/plugin-config.yaml` 的 valuesTemplates 在安装时通过 `<< .RegistryAddress >>` 自动重写为当前集群的内置镜像仓库地址）。
- `jaeger-image` / `jaeger-es-rollover-image` / `jaeger-es-index-cleaner-image` / `oauth2-proxy-image`：各镜像的**完整可拉取地址**（含 registry 前缀），可直接在部署调用链组件时引用。

> 用 `helm template` 在本地渲染时，registry 字段还是 `values.yaml` 默认值 `build-harbor.alauda.cn`（即镜像源地址），属正常现象。该字段只有在 ACP 安装时才会被 valuesTemplates 重写为平台内置 registry。

## 构建与发布

chart 由 GitHub Actions 流水线 [`alauda-build-jaeger.yaml`](../../.github/workflows/alauda-build-jaeger.yaml) 的 `build-cluster-plugin` job 自动构建并推送：

- 推送 release tag（如 `plugin-v2.1.0-r0`）或手动触发时：`build-harbor.alauda.cn/asm/jaeger-cluster-plugin:v2.1.0-r0`
- PR 构建：`build-harbor.alauda.cn/asm/jaeger-cluster-plugin:v2.1.0-pr.<PR号>.<运行号>`（版本基线取 `Chart.yaml` 的 `version` 字段）

流水线会先执行 `hack/update-version.sh`，写入本次构建的 chart 版本与上游 Jaeger 版本（3 个 Jaeger 镜像 tag 由两者拼接，与同一流水线构建出的镜像一致），并将 `Chart.yaml` 中 `org.opencontainers.image.*` provenance 注解的占位符替换为实际的 commit 与分支/标签信息。构建完成后，`output-images` job 会汇总输出全部镜像与 chart 的地址。

### 本地打包测试

```bash
helm lint jaeger-cluster-plugin/
helm package jaeger-cluster-plugin/
helm registry login build-harbor.alauda.cn
helm push jaeger-cluster-plugin-<chart-version>.tgz oci://build-harbor.alauda.cn/asm
```

### 用 violet 打包并上架到 ACP

```bash
violet create jaeger-cluster-plugin \
  --artifact build-harbor.alauda.cn/asm/jaeger-cluster-plugin:<chart-version> \
  --platforms linux/amd64,linux/arm64 \
  --username <harbor-user> \
  --password <harbor-pass>

violet package jaeger-cluster-plugin \
  --username <harbor-user> \
  --password <harbor-pass>

violet push jaeger-cluster-plugin-<chart-version>.tgz \
  --platform-address https://<acp-host> \
  --platform-username <acp-user> \
  --platform-password <acp-pass>
```

## 安装与卸载

平台管理 → 集群管理 → 选择目标集群 → 插件 → 找到 `Alauda Build of Jaeger v2` → 部署 / 卸载。

也可以在 global 集群创建 ModuleInfo 通过 CLI 安装，详见 ACP 文档《Cluster Plugin》。

## 如何更新版本

chart 版本号与 Jaeger 镜像 tag 分布在多个文件中，直接使用脚本一次性同步：

```bash
./hack/update-version.sh <CHART_VERSION> <JAEGER_VERSION>
# 示例（第 1 个参数为集群插件版本，第 2 个参数为上游 Jaeger 版本；
# 3 个 Jaeger 镜像 tag 自动拼接为 <Jaeger 版本>-<插件版本去 v 前缀>）：
./hack/update-version.sh v2.1.0-r0 2.16.0
```

两种常见场景：

- **插件发版**：确认版本后打 tag `plugin-<新版本>`（如 `plugin-v2.1.0-r1`），CI 自动以 tag 中的版本构建；
- **同步上游 Jaeger 新版本**：更新代码后修改 [`Chart.yaml`](./Chart.yaml) 的 `appVersion`（或直接运行上述脚本），并按发版节奏递增插件版本。

更新 oauth2-proxy 版本时直接修改 [`values.yaml`](./values.yaml) 中 `oauth2-proxy.tag` 即可（保留行尾的 `# oauth2-proxy-tag` 标记）。

## 约束

- 所有镜像必须与主 chart 在同一个 registry domain（即 `global.registry.address`）。violet 在打包时会用主 chart 的 OCI artifact 地址作为唯一 domain 拼装镜像 URL。
- `values.yaml` 中 `global.images.<name>.repository` 必须是仓库相对路径，**不能**包含 registry 前缀，否则会被拼成错误的双域名地址。
