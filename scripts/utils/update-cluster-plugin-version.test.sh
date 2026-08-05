#!/bin/bash

# Copyright (c) 2026 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

# 使用 https://github.com/kward/shunit2 运行单元测试。
SHUNIT2="${SHUNIT2:?'SHUNIT2 环境变量必须指向 shunit2 目录'}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
PLUGIN_ROOT="$REPO_ROOT/alauda/jaeger-cluster-plugin"

setUp() {
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/hack"
  cp "$PLUGIN_ROOT/hack/update-version.sh" "$TEST_DIR/hack/update-version.sh"
  cp "$PLUGIN_ROOT/Chart.yaml" "$TEST_DIR/Chart.yaml"
  cp "$PLUGIN_ROOT/module-plugin.yaml" "$TEST_DIR/module-plugin.yaml"
  cp "$PLUGIN_ROOT/values.yaml" "$TEST_DIR/values.yaml"
}

tearDown() {
  rm -rf "$TEST_DIR"
}

testAcceptsReleaseCandidateVersion() {
  output=$(bash "$TEST_DIR/hack/update-version.sh" v2.1.0-rc.3 2.16.0 2>&1)
  rc=$?

  assertEquals "rc 版本应校验成功" 0 "$rc"
  assertContains "$output" '已更新 chart 版本为：v2.1.0-rc.3'
  assertEquals 'v2.1.0-rc.3' "$(sed -n 's/^version: //p' "$TEST_DIR/Chart.yaml")"
  assertEquals 'v2.1.0-rc.3' "$(sed -n 's/^      version: //p' "$TEST_DIR/module-plugin.yaml")"
  assertEquals 3 "$(grep -c 'tag: "2.16.0-2.1.0-rc.3" # jaeger-tag$' "$TEST_DIR/values.yaml")"
}

testRejectsReleaseCandidateVersionWithoutDot() {
  output=$(bash "$TEST_DIR/hack/update-version.sh" v2.1.0-rc3 2.16.0 2>&1)
  rc=$?

  assertEquals "rc 序号前缺少点号时应校验失败" 1 "$rc"
  assertContains "$output" 'vX.Y.Z-rc.N'
}

# shellcheck disable=SC1091
source "${SHUNIT2}/shunit2"
