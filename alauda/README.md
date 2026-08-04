# Alauda's Jaeger Distribution

## 版本更新

1. 同步上游新版本（tag）代码：更新 `main` 分支以跟踪上游 [jaegertracing/jaeger](https://github.com/jaegertracing/jaeger) 最新发布版本。
2. 同步后更新 [jaeger-cluster-plugin/Chart.yaml](./jaeger-cluster-plugin/Chart.yaml) 的 `appVersion` 为新的上游版本（如 `2.17.0`），CI 流水线以该字段作为 Jaeger 版本的事实源。

## Release

版本采用两条独立的版本轴：

- **Jaeger 版本**（如 `2.16.0`）：与上游开源版本保持同步，维护在 [jaeger-cluster-plugin/Chart.yaml](./jaeger-cluster-plugin/Chart.yaml) 的 `appVersion` 字段。
- **集群插件版本**（如 `v2.1.0-r0`）：Alauda Build of Jaeger v2 集群插件自身的发版节奏，由 git tag 驱动；Jaeger 升级时建议递增 minor（如 `v2.2.0-r0`），仅 chart 修复时递增 rN。

创建格式为 `plugin-vx.y.z-rn`（例如 `plugin-v2.1.0-r0`）的 tag 后，构建 action 将自动触发。tag 带 `plugin-` 前缀，以与上游 Jaeger 版本 tag（如 `v2.16.0`）区分，避免干扰 `scripts/utils/compute-version.sh` 基于 git tag 的 Jaeger 版本推导。

构建产物包含以下组件的多架构镜像（linux/amd64, linux/arm64）：

| 组件             | 镜像地址                                            | 说明                   |
| ---------------- | --------------------------------------------------- | ---------------------- |
| jaeger           | `build-harbor.alauda.cn/asm/jaeger`                 | Jaeger 主服务（含 UI） |
| es-rollover      | `build-harbor.alauda.cn/asm/jaeger-es-rollover`     | ES 索引滚动工具        |
| es-index-cleaner | `build-harbor.alauda.cn/asm/jaeger-es-index-cleaner`| ES 索引清理工具        |

镜像 tag 结构为 `<Jaeger 版本>-<插件版本去 v 前缀>`（示例：`2.16.0-2.1.0-r0`），同时携带 Jaeger 版本与插件版本，与集群插件 chart 版本一一对应。

流水线同时会构建 **Alauda Build of Jaeger v2 集群插件** chart（`build-harbor.alauda.cn/asm/jaeger-cluster-plugin`，tag 为插件版本，如 `v2.1.0-r0`），用于随 ACP 集群插件分发上述 3 个 Jaeger 镜像与 oauth2-proxy 镜像，详见 [jaeger-cluster-plugin/README.md](./jaeger-cluster-plugin/README.md)。

本次构建的全部产物地址（3 个 Jaeger 镜像、oauth2-proxy 镜像、集群插件 chart）会在流水线的 `output-images` job 中汇总输出。

## Oauth2 Proxy 镜像更新

**注：该镜像暂时不需要自行构建。**

同步上游开源镜像（新版本或修复了安全漏洞的版本）。

> **注意**：build-harbor.alauda.cn 的 tag 配置为不可变（immutable），同一 tag 只允许推送一次，之后无法覆盖推送——因此**不能**先把镜像推到最终 tag、再用 `crane mutate` 原地补 label（第二次推送会被 `PRECONDITION ... configured as immutable` 拒绝）。需按下述顺序操作：先同步到临时 tag，补全 label 后再写入最终 tag，让最终 tag 的唯一一次推送就携带完整的 provenance 元数据。

1. 从 quay.io 同步镜像到**临时 tag**（仅保留 linux/amd64、linux/arm64 两个架构）：

   ```bash
   crane index filter \
     quay.io/oauth2-proxy/oauth2-proxy:<version-tag> \
     -t build-harbor.alauda.cn/asm/oauth2-proxy:<version-tag>-tmp \
     --platform linux/amd64 \
     --platform linux/arm64
   # 示例：
   crane index filter \
     quay.io/oauth2-proxy/oauth2-proxy:v7.15.2 \
     -t build-harbor.alauda.cn/asm/oauth2-proxy:v7.15.2-tmp \
     --platform linux/amd64 \
     --platform linux/arm64
   ```

2. 以临时 tag 为源补充 OCI provenance 元数据，并写入**最终 tag**。上游镜像已带 `org.opencontainers.image.source` 标签，还需补充 `org.opencontainers.image.revision`（上游 tag 对应的 commit SHA）与 `org.opencontainers.image.ref.name`（上游 tag）：

   ```bash
   # 查询上游 tag 对应的 commit SHA（annotated tag 取带 ^{} 的那行）
   git ls-remote --tags https://github.com/oauth2-proxy/oauth2-proxy.git '<version-tag>*'

   # 补充 provenance 标签并写入最终 tag（需要 crane >= v0.13，会对 index 内各架构镜像生效；
   # 最终 tag 仅在此处推送一次，不会触发 immutable 限制）
   crane mutate build-harbor.alauda.cn/asm/oauth2-proxy:<version-tag>-tmp \
     --label "org.opencontainers.image.revision=<upstream-commit-sha>" \
     --label "org.opencontainers.image.ref.name=<version-tag>" \
     -t build-harbor.alauda.cn/asm/oauth2-proxy:<version-tag>-r<n>
   # 示例：
   crane mutate build-harbor.alauda.cn/asm/oauth2-proxy:v7.15.2-tmp \
     --label "org.opencontainers.image.revision=$(git ls-remote https://github.com/oauth2-proxy/oauth2-proxy.git 'refs/tags/v7.15.2^{}' | cut -f1)" \
     --label "org.opencontainers.image.ref.name=v7.15.2" \
     -t build-harbor.alauda.cn/asm/oauth2-proxy:v7.15.2-r0
   ```

3. 删除临时 tag。`crane mutate` 产生了新的 manifest，最终 tag 与临时 tag 指向不同 digest，删除临时 tag 不影响最终 tag：

   ```bash
   crane delete build-harbor.alauda.cn/asm/oauth2-proxy:<version-tag>-tmp
   # 示例：
   crane delete build-harbor.alauda.cn/asm/oauth2-proxy:v7.15.2-tmp
   ```

   > 若临时 tag 也命中了 Harbor 的 tag 不可变规则导致删除被拒，在 Harbor 界面手动清理即可，不影响最终产物。

同步完成后，更新 [jaeger-cluster-plugin/values.yaml](./jaeger-cluster-plugin/values.yaml) 中 `oauth2-proxy.tag` 为新版本（保留行尾的 `# oauth2-proxy-tag` 标记，CI 流水线依赖它读取并输出该版本）。

## 本地构建

```bash
# 构建 jaeger（含 UI）
make build-jaeger
# 验证构建产物
./cmd/jaeger/jaeger-$(go env GOOS)-$(go env GOARCH) --help

# 构建 es-rollover
make build-es-rollover
# 验证构建产物
./cmd/es-rollover/es-rollover-$(go env GOOS)-$(go env GOARCH) --help

# 构建 es-index-cleaner
make build-es-index-cleaner
# 验证构建产物
./cmd/es-index-cleaner/es-index-cleaner-$(go env GOOS)-$(go env GOARCH) --help
```
