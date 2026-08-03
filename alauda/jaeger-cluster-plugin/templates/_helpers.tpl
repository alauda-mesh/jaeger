{{- define "jaeger-cluster-plugin.name" -}}
jaeger-cluster-plugin
{{- end -}}

{{- define "jaeger-cluster-plugin.labels" -}}
cpaas.io/module-name: jaeger-cluster-plugin
cpaas.io/module-type: plugin
app.kubernetes.io/name: jaeger-cluster-plugin
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
通过镜像名（即 .Values.global.images 的 key）拼出该镜像在当前集群下的完整可拉取地址。
registry 来自 .Values.global.registry.address，ACP 安装时会被 scripts/plugin-config.yaml
的 valuesTemplates 重写为平台内置镜像仓库，因此渲染结果就是用户可直接使用的最终镜像地址。
用法：
  image: {{ include "jaeger-cluster-plugin.image" (dict "ctx" . "name" "jaeger") }}
*/}}
{{- define "jaeger-cluster-plugin.image" -}}
{{- $img := index .ctx.Values.global.images .name -}}
{{- printf "%s/%s:%s" .ctx.Values.global.registry.address $img.repository $img.tag -}}
{{- end -}}
