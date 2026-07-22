# 从 enforce-4-step-method 迁移

## 迁移原因

`enforce-4-step-method` 和 `harness-4step` 两个仓库内容完全相同，
为了简化维护，将所有内容整合到 `harness-4step` 仓库中。

## 迁移日期

2026-07-22

## 变更内容

- 两个仓库的 SKILL.md、plugin/ 文件完全相同，无需合并
- `harness-4step` 包含额外的 references/ 和 scripts/ 目录
- 版本号统一为 2.0.0

## 如何迁移

1. 克隆新仓库：
   ```bash
   git clone https://github.com/flamebird07/harness-4step.git
   ```

2. 复制插件到正确位置：
   ```bash
   cp -r harness-4step/plugin/ ~/AppData/Local/hermes/plugins/four-step-enforcer/
   ```

3. 启用插件（编辑 config.yaml）：
   ```yaml
   plugins:
     enabled:
       - four-step-enforcer
   ```

## 原始仓库

- enforce-4-step-method: https://github.com/flamebird07/enforce-4-step-method (已归档)
- harness-4step: https://github.com/flamebird07/harness-4step (主仓库)
