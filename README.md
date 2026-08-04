# 4步法强制执行系统 (Harness 4-Step Method)

> **v13.0.1** — 绑定锁 + 原子队列 + 递归拆分；Step 1/2/3 使用 Claude Code CLI，Step 4 使用 MiMo Code CLI（以 binding-lock.json 为准）

## 系统组成

| 组件 | 作用 |
|------|------|
| SKILL.md | 定义4步法规则和流程（v13.0.1） |
| plugin/ | harness-4step 技术强制执行插件 |
| references/ | 参考文档（CLI 语法、故障诊断、会话取证） |
| scripts/ | 工具脚本 |

## 4步法流程

| 步骤 | Agent（固定绑定） | Real CLI | 超时 | 限制 |
|------|-----------------|----------|------|------|
| Step 1 | **Claude Code CLI**（以 binding-lock.json 为准） | `run_cli.py --step step1` | 120s | 只审查，不能改代码 |
| Step 2 | **Claude Code CLI**（以 binding-lock.json 为准） | `run_cli.py --step step2` | 120s | 只出方案，不能改代码 |
| Step 3 | **Claude Code CLI**（以 binding-lock.json 为准） | `run_cli.py --step step3` | 300s | 按方案执行修改，不能做方案/审查 |
| Step 4 | **MiMo Code CLI**（以 binding-lock.json 为准） | `run_cli.py --step step4` | 180s | 复审，不能改代码 |

**核心原则：每步 CLI 绑定后不可更改。** 绑定以 `binding-lock.json` 为准，用户设定后永久锁定，超时只重试不降级。

**循环机制**：Step 4 发现问题 → 回到 Step 2 → Step 3 → Step 4，最多 10 轮。

## To-Do 队列与自动拆分

每个任务都有 `~/.hermes/harness-workspace/<task-id>/todo.json`。队列只允许原子问题：一个验收目标、明确文件范围、可独立验证。同一只读步骤第二次失败/超时，item 自动标记 `split_required`，必须拆成子项。所有待办清零并通过总审查，才算完工。

## 快速开始

### 1. 安装技能

```bash
cp -r harness-4step ~/.hermes/skills/
```

### 2. 安装插件（可选，技术强制执行）

```bash
cp -r plugin/harness-4step ~/.hermes/plugins/
```

### 3. 使用

在 Hermes 对话中加载技能：
```
/skill harness-4step
```

## 版本历史

- v13.0.1 (2026-08-04): 修复实际插件被全量豁免且未启用、CLI 配置可静默漂移的根因；新增 binding-lock、原子 to-do 状态机、二次只读失败强制拆分、每步报告、直接 CLI/直接写入反绕过门禁，并启用 four-step-enforcer。

## 许可证

MIT
