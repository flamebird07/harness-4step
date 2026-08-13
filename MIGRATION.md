# 从 enforce-4-step-method 迁移（旧名称，已归档/已重命名）

> 历史归档上下文：`enforce-4-step-method` 是 `harness-4step` 的旧名（已于 2026-07-29 彻底移除，不存在名为 `enforce-4-step-method` 的技能）。本文档仅作迁移记录；当前唯一有效名称是 `harness-4step`。

## 迁移原因

`enforce-4-step-method`（旧名，已归档）和 `harness-4step` 两个仓库内容完全相同，
为了简化维护，将所有内容整合到 `harness-4step` 仓库中。

## 迁移日期

2026-07-22

## 变更内容

- 两个仓库的 SKILL.md、plugin/ 文件完全相同，无需合并
- `harness-4step` 包含额外的 references/ 和 scripts/ 目录
- 版本号统一（当前版本见 SKILL.md frontmatter，v13.0.16）

## 如何迁移（当前安装方式）

1. 克隆仓库：
   ```bash
   git clone https://github.com/flamebird07/harness-4step.git
   ```

2. 复制技能到 Hermes skills 目录：
   ```bash
   cp -r harness-4step ~/.hermes/skills/
   ```

3. 复制插件到正确位置（可选，技术强制执行）：
   ```bash
   cp -r harness-4step/plugin ~/.hermes/plugins/harness-4step
   ```

4. 启用插件（编辑 config.yaml）：
   ```yaml
   plugins:
     enabled:
       - harness-4step
   ```

## 原始仓库

- enforce-4-step-method: https://github.com/flamebird07/enforce-4-step-method (旧名，已归档)
- harness-4step: https://github.com/flamebird07/harness-4step (主仓库，当前唯一有效名称)
