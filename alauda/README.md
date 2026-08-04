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

> **注意**：build-harbor.alauda.cn 的 tag 配置为不可变（immutable），同一 tag 只允许推送一次，之后无法覆盖也无法删除。因此不要把镜像先推到 registry 再修改，而是用 [regctl](https://github.com/regclient/regclient)（macOS 安装：`brew install regclient`）在本地完成"过滤架构 + 补 label"，最后一次性推送最终 tag。推送前一切都在本地目录中，可自检、可反悔，registry 上只会出现一次成型的最终 tag。

1. 全量同步上游镜像到本地 OCI layout（会在当前目录生成 `o2p/` 工作目录）：

   ```bash
   regctl image copy quay.io/oauth2-proxy/oauth2-proxy:<version-tag> ocidir://o2p:src
   # 示例：
   regctl image copy quay.io/oauth2-proxy/oauth2-proxy:v7.15.2 ocidir://o2p:src
   ```

2. 本地裁剪出 linux/amd64、linux/arm64 两个架构（上游其余平台与 buildkit attestation 一并丢弃）：

   ```bash
   regctl index create ocidir://o2p:filtered --ref ocidir://o2p:src \
     --platform linux/amd64 --platform linux/arm64
   ```

3. 本地补充 OCI provenance 元数据（对 index 内全部架构生效）。上游镜像已带 `org.opencontainers.image.source` 标签，还需补充 `org.opencontainers.image.revision`（上游 tag 对应的 commit SHA）与 `org.opencontainers.image.ref.name`（上游 tag）：

   ```bash
   # 查询上游 tag 对应的 commit SHA（annotated tag 取带 ^{} 的那行）
   git ls-remote --tags https://github.com/oauth2-proxy/oauth2-proxy.git '<version-tag>*'

   regctl image mod ocidir://o2p:filtered \
     --label "org.opencontainers.image.revision=<upstream-commit-sha>" \
     --label "org.opencontainers.image.ref.name=<version-tag>" \
     --create ocidir://o2p:final
   # 示例：
   regctl image mod ocidir://o2p:filtered \
     --label "org.opencontainers.image.revision=$(git ls-remote https://github.com/oauth2-proxy/oauth2-proxy.git 'refs/tags/v7.15.2^{}' | cut -f1)" \
     --label "org.opencontainers.image.ref.name=v7.15.2" \
     --create ocidir://o2p:final
   ```

4. 本地自检架构列表与 label，确认无误后登录并一次性推送**最终 tag**（唯一一次推送，不触发 immutable 限制）：

   ```bash
   # 自检：index 应只含 amd64/arm64 两个平台，各平台 Labels 应含完整 provenance 三键
   regctl manifest get ocidir://o2p:final
   regctl image config ocidir://o2p:final -p linux/amd64 --format '{{json .Config.Labels}}'
   regctl image config ocidir://o2p:final -p linux/arm64 --format '{{json .Config.Labels}}'

   regctl registry login build-harbor.alauda.cn
   regctl image copy ocidir://o2p:final build-harbor.alauda.cn/asm/oauth2-proxy:<version-tag>-r<n>
   # 示例：
   regctl image copy ocidir://o2p:final build-harbor.alauda.cn/asm/oauth2-proxy:v7.15.2-r1
   ```

   > 若推送报 `configured as immutable`，说明最终 tag 已被占用（例如此前误推过未打 label 的版本），被占用的 tag 无法覆盖也无法修复，换下一个 `-r<n>` 序号重推即可（可用 `regctl image config build-harbor.alauda.cn/asm/oauth2-proxy:<tag> -p linux/amd64 --format '{{json .Config.Labels}}'` 检查已占用 tag 是否携带完整 label）。推送完成后本地 `o2p/` 目录可直接删除。

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
