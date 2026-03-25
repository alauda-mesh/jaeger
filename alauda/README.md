# Alauda's Jaeger Distribution

## 版本更新

1. 同步上游新版本（tag）代码：更新 `main` 分支以跟踪上游 [jaegertracing/jaeger](https://github.com/jaegertracing/jaeger) 最新发布版本。

## Release

创建格式为 `vx.y.z-rn`（例如 `v2.16.0-r0`）的 tag 后，镜像构建 action 将自动触发。

构建产物包含以下组件的多架构镜像（linux/amd64, linux/arm64）：

| 组件        | 镜像地址                                 | 说明                   |
| ----------- | ---------------------------------------- | ---------------------- |
| jaeger      | `build-harbor.alauda.cn/asm/jaeger`      | Jaeger 主服务（含 UI） |
| es-rollover | `build-harbor.alauda.cn/asm/es-rollover` | ES 索引滚动工具        |

镜像 tag 示例：`2.16.0-r0`
