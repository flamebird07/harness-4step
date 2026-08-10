---
name: four-step-harness
description: "四步法 Harness + Loops 循环机制：审查→方案→执行→复审→循环直到通过。用独立 subagent 保证每步思维互不干扰、跳出逻辑死角；裁判不能当运动员。单一项目兼容 Hermes/opencode，共享逻辑见仓库 shared/。Use when the user asks to run 四步法/4step/four-step harness/审查出方案执行复审/code review loop, or wants a bug fixed through separated audit-plan-implement-verify roles."
---

# 四步法 Harness（opencode 适配层）

**逻辑源 = 仓库 `shared/core-logic.md`。** 本文件只做 opencode 落地：把共享逻辑映射到 opencode 的 subagent 与工具，不复制逻辑实现。逻辑有缺陷去改 shared/，本层只跟着更新引用。

**核心原则：裁判不能当运动员。** 每步独立互不干扰，不同 agent 以独立思维挑出彼此的逻辑死角。

## 与 Hermes 版的关系（单一项目）

| 维度 | Hermes 适配层 | opencode 适配层（本文件） |
|------|--------------|---------------------------|
| 执行后端 | `run_cli.py` + `binding-lock.json`（每步绑外部 CLI） | Task 调度 `harness-*` subagent + bash 调 CLI（可选） |
| 反绕过 | `plugin/four-step-enforcer` | subagent `permission: edit: deny`（系统级） |
| 队列/超时/拆分 | Hermes 专属机制 | 不复制，opencode 用任务清单+估算即可 |

## 后端绑定（每步选择性）

每步默认用宿主内 subagent；如需跨模型族拉大思维差异，某步可改为 bash 调外部 CLI（`codex`/`claude`/`mimo`/`kimi`，命令见 `shared/binding-recommendation.md`），或给 subagent frontmatter 配不同 `model:`。

**核心约束（不可违反）**：Step 4 复审必须与 Step 3 使用不同模型族。

## 角色与权限映射（4 个独立 subagent）

| 步骤 | 角色 | subagent | 权限 | 职责 |
|------|------|----------|------|------|
| 1 | 审查 | `harness-auditor` | edit: deny | 只找问题，不写方案（P 编号） |
| 2 | 方案 | `harness-planner` | edit: deny | 只写计划（F-<P编号> + before/after） |
| 3 | 执行 | `harness-implementer` | edit: allow | 严格按方案改，不分析 |
| 4 | 复审 | `harness-verifier` | edit: deny | 独立验证（读实际代码 + 跑回归） |

每次 Task 调用都是**全新独立上下文**，只传问题描述/上一步产物，**不传主 agent 的分析结论**，避免污染下一个 agent 的独立判断。

## 编排流程（主 agent 用 Task 工具）

1. **Step 0** 建工作区 `.harness/<task>/`，告知用户产物落盘位置。
2. **Step 1** `harness-auditor`：入参 = 问题 + 文件路径 → `step1-problems.md`（P 编号）。零问题则终止报告。
3. **Step 2** `harness-planner`：入参 = 问题清单 → `step2-plan.md`（F-<P编号>）。
4. **Step 2.5** 基线：git 仓库 `git diff > baseline.diff`；非 git 复制到 `backup/`。
5. **Step 3** `harness-implementer`：入参 = 方案 → 逐条 before→after，产出 `step3-changes.md`。执行后对比基线验无方案外改动。
6. **Step 4** `harness-verifier`：入参 = 修改后代码 + 问题清单 → **读实际文件核对 + 跑测试/lint** → `step4-review.md`，评级 `通过`/`需调整`。
7. **循环**：`需调整` → 回 Step 2（只处理未通过的 P + 新阻塞；入参加挂上轮复审）。Step 1 只做一次。上限 3 次，超限汇报未解决问题。

## 硬性规则（主 agent）

- 每步等上一 subagent 返回后才进下一步；不可并行、不可跳步
- 主 agent 不得自己分析根因、写方案、改代码
- 传参只传原始问题/产物，禁止夹带倾向性结论
- Step 3 完成后必须立即进入 Step 4，不得中途停下汇报当"完成"

## 违规处理

越权修改文件：用 `baseline.diff`/备份精确回退 → 从违规点重走 → 记录到 `violations.log`。

更多细节（推荐矩阵、编号、循环、终止条件）见仓库 `shared/core-logic.md` 与 `shared/binding-recommendation.md`。