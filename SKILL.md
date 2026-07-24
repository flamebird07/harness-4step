---
name: enforce-4-step-method
description: "Enforce the 4-step method: Codex CLI Review → Codex CLI Plan → MiMo Code Execute → Kimi CLI K3 Re-review"
version: 3.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [enforcement, workflow, rules, compliance]
    related_skills: [writing-plans, subagent-driven-development]
---

# Enforce 4-Step Method (v3 — Real CLI Execution)

## Overview

This skill enforces the 4-step method for code changes. Each step MUST be executed by calling the real CLI tool via `run_cli.py` — NOT by labeling `delegate_task` goals with role names.

## Core Principle

**Role label ≠ Execution.** The `【角色：Codex CLI】` prefix in `delegate_task` goal fields does NOT execute Codex CLI. Real CLI execution requires spawning an actual process via `scripts/run_cli.py`.

## The 4-Step Method

**MANDATORY for all code changes:**

| Step | Agent | Real CLI | 限制 |
|------|-------|----------|------|
| Step 1 | **Codex CLI** | `codex exec` | ❌ 不能改代码 |
| Step 2 | **Codex CLI** | `codex exec` | ❌ 不能改代码 |
| Step 3 | **MiMo Code** | `codex exec --model mimo` | ❌ 不能做方案/审查 |
| Step 4 | **Kimi CLI K3** | `kimi -p` | ❌ 不能改代码 |

## CLI Execution Contract (MUST)

### 每步必须通过 run_cli.py 调用真实 CLI

```bash
python scripts/run_cli.py \
  --step step1 \
  --task-id <unique-task-id> \
  --workspace <project-root> \
  --prompt "<step-specific-prompt>"
```

### 禁止行为

- ❌ 用 `delegate_task` 返回文本冒充 CLI 输出
- ❌ 手工创建 `evidence.json`
- ❌ 仅检查 `subprocess` 启动成功
- ❌ CLI 失败后继续推进步骤
- ❌ 在 goal 字段标注角色但不调用对应 CLI

### 完成条件

每步必须同时满足：
1. `run_cli.py` 返回 `exit_code: 0`
2. `stdout` 非空
3. `evidence.json` 存在且 `success: true`
4. 输出内容满足该步骤的语义要求

### 证据验证

```bash
python scripts/run_cli.py \
  --step step1 \
  --task-id <task-id> \
  --workspace . \
  --verify-only
```

返回 `{"success": true, "message": "OK"}` 表示验证通过。

## 派发模板（MUST）

每步执行流程：

1. **准备 prompt 文件**（写入临时文件）
2. **调用 run_cli.py**（真实 CLI 执行）
3. **检查 evidence.json**（验证执行结果）
4. **汇报执行结果**（含退出码、agent_message）

```
## Step X 执行汇报

| 项目 | 内容 |
|------|------|
| 当前步骤 | Step X |
| 执行Agent | [Agent名称] |
| CLI调用 | run_cli.py --step stepX |
| 退出码 | 0 |
| 证据验证 | ✅ PASS |
| agent_message | [前200字] |
```

## Loops Mechanism

When Step 4 fails, the process loops back to Step 2:

```
Step 1 → Step 2 → Step 3 → Step 4
                ↑               │
                │    FAIL       │
                └───────────────┘
```

**Maximum Loops:** 10

## Task Directory

Each task creates a directory:
```
~/.hermes/harness-workspace/<task-id>/
├── step1/
│   ├── prompt.txt
│   ├── stdout.jsonl
│   ├── stderr.txt
│   └── evidence.json
├── step2/
├── step3/
└── step4/
```

## Agent Capabilities

| Agent | Can Do | Cannot Do |
|-------|--------|-----------|
| Codex CLI (Step 1/2) | Review, Analyze, Plan, Verify | Modify code |
| MiMo Code (Step 3) | Execute code changes | Review |
| Kimi CLI K3 (Step 4) | Re-review, Verify | Modify code |

## Configuration

File: `~/.hermes/harness-bindings.yaml`

```yaml
step1_review:   codex
step2_plan:     codex
step3_execute:  mimo
step4_rereview: kimi-cli

locks:
  step1_review:   false
  step2_plan:     false
  step3_execute:  false
  step4_rereview: false
```

## Version History

- v3.0.0 (2026-07-24): Real CLI execution via run_cli.py. Role labels no longer sufficient.
- v2.2.0 (2026-07-22): Updated step1/2 to Codex CLI, step4 to Kimi CLI K3
- v2.1.0 (2026-07-22): Added plugin enforcement system
- v2.0.0 (2026-07-22): Updated to use Kimi CLI/MiMo Code/Codex CLI
- v1.0.0 (2026-07-21): Initial version with Loops mechanism
