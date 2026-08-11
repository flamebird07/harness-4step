---
name: four-step-harness
description: "四步法 Harness + Loops 循环机制：审查→方案→执行→复审→循环直到通过。用独立 subagent 保证每步思维互不干扰、跳出逻辑死角；裁判不能当运动员。单一项目兼容 Hermes/opencode，共享逻辑见仓库 shared/。Use when the user asks to run 四步法/4step/four-step harness/审查出方案执行复审/code review loop, or wants a bug fixed through separated audit-plan-implement-verify roles."
version: 13.0.12
---

# 四步法 Harness（opencode 适配层）

**逻辑源 = 仓库 `shared/core-logic.md`。** 本文件只做 opencode 落地：把共享逻辑映射到 opencode 的 subagent 与工具，不复制逻辑实现。逻辑有缺陷去改 shared/，本层只跟着更新引用。

**核心原则：裁判不能当运动员。** 每步独立互不干扰，不同 agent 以独立思维挑出彼此的逻辑死角。

## 与 Hermes 版的关系（单一项目）

| 维度 | Hermes 适配层 | opencode 适配层（本文件） |
|------|--------------|---------------------------|
| 执行后端 | `run_cli.py` + `binding-lock.json`（每步绑外部 CLI） | Task 调度 `harness-*` subagent（step1-3）+ bash 调 codex CLI（step4） |
| 反绕过 | `plugin/four-step-enforcer` | subagent `permission: edit: deny`（系统级） |
| 队列/超时/拆分 | Hermes 专属机制 | 不复制，opencode 用任务清单+估算即可 |

## 后端绑定（当前锁定配置）

**绑定来源**：opencode 侧的绑定即下表（subagent + 外部 CLI 混合），变更必须用户显式授权；不依赖 Hermes 的 `~/.hermes/binding-lock.json`。当前绑定：
- **step1 = `harness-auditor` subagent**（主模型，edit: deny）
- **step2 = `harness-planner` subagent**（主模型，edit: deny）
- step3 = opencode `harness-implementer` subagent（主模型，edit: allow）
- **step4 = codex CLI（外部独立模型族）**——通过 bash 调 `opencode/scripts/run_codex_step4.ps1` 执行
- 备用：mimo CLI 已配好 `opencode/scripts/run_mimo_step4.ps1`（认证失效时临时切换，需用户授权）

**核心约束（不可违反）**：Step 4 复审必须与 Step 3 使用不同模型族（step4 为外部 CLI，step1-3 为主模型，天然满足）。

## 角色与权限映射

| 步骤 | 角色 | 后端 | 权限 | 职责 |
|------|------|------|------|------|
| 1 | 审查 | `harness-auditor` subagent | edit: deny | 只找问题，不写方案（P 编号） |
| 2 | 方案 | `harness-planner` subagent | edit: deny | 只写计划（F-<P编号> + before/after） |
| 3 | 执行 | `harness-implementer` subagent | edit: allow | 严格按方案改，不分析 |
| 4 | 复审 | **codex CLI**（playbook: `opencode/scripts/run_codex_step4.ps1`） | 只读验证天然隔离 | 独立验证（读实际代码 + 跑回归） |

- step1-3 每次 Task 调用都是**全新独立上下文**，只传问题描述/上一步产物，**不传主 agent 的分析结论**。
- step4 由主 agent 用 bash 调 codex CLI，独立进程独立上下文。

## codex CLI 调用规范（step4 当前绑定）

```powershell
# 把复审 prompt 写入 .harness/<task>/step4-prompt.txt 后执行：
& "opencode\scripts\run_codex_step4.ps1" `
    -PromptFile ".harness\<task>\step4-prompt.txt" `
    -WorkspaceDir "<仓库或工作目录>" `
    -OutDir ".harness\<task>\step4"
# 产物：step4/codex_raw.jsonl（原始输出）、step4/step4-review.md（提取的 agent_message + 环境信息）
# 路径说明：仓库内用 opencode/ 相对路径；按 opencode/README.md 安装后脚本位于 <skill 目录>/scripts/，
# 调用对应改为 & "<skill 目录>\scripts\run_codex_step4.ps1"
```

- **连接前提**：脚本按 PATH 解析 `codex`；PATH 无 codex 时回退 `CODEX_HOME\.sandbox-bin\codex.exe`（`CODEX_HOME` 默认 `~/.ccsc/codex-mimo`，可用环境变量覆盖）。若认证失效会 401，需用户 `codex login`（或在 Codex 应用重新登录）。
- prompt 必须包含：step1 原始问题清单（P 编号）+ 修改后文件绝对路径 + 明确要求"打开实际文件核对、能跑回归就跑、逐条评级、输出总体 通过/需调整"。
- 传给 codex 的 prompt 只含事实（问题 + 文件路径），不含主 agent 的倾向性结论。
- 若输出含 `NO agent_message` 或 `EXIT_CODE=-1`，重试一次；仍失败则记录后向用户汇报。

## mimo CLI 调用规范（step4 备用）

```powershell
& "opencode\scripts\run_mimo_step4.ps1" `
    -PromptFile ".harness\<task>\step4-prompt.txt" `
    -WorkspaceDir "<仓库或工作目录>" `
    -OutDir ".harness\<task>\step4"
# 产物：step4/mimo_raw.txt（原始输出）、step4/step4-review.md
# 路径说明：仓库内用 opencode/ 相对路径；按 opencode/README.md 安装后脚本位于 <skill 目录>/scripts/，
# 调用对应改为 & "<skill 目录>\scripts\run_mimo_step4.ps1"
```

- 仅当 codex 认证失效且用户显式授权切 mimo 时使用。模型默认 `xiaomi/mimo-v2.5-pro`。

## 编排流程（主 agent 用 Task 工具）

1. **Step 0** 建工作区 `.harness/<task>/`，告知用户产物落盘位置。
2. **Step 1** `harness-auditor`：入参 = 问题 + 文件路径 → `step1-problems.md`（P 编号）。零问题则终止报告。
3. **Step 2** `harness-planner`：入参 = 问题清单 → `step2-plan.md`（F-<P编号>）。
4. **Step 2.5** 基线：git 仓库 `git diff > baseline.diff`；非 git 复制到 `backup/`。
5. **Step 3** `harness-implementer`：入参 = 方案 → 逐条 before→after，产出 `step3-changes.md`。执行后对比基线验无方案外改动。
6. **Step 4** **codex CLI**：入参 = 修改后代码绝对路径 + step1 问题清单 → 写 `step4-prompt.txt` → 调 `opencode/scripts/run_codex_step4.ps1` → 读取 `step4/step4-review.md`，评级 `通过`/`需调整`。
7. **循环**：`需调整` → 回 Step 2（只处理未通过的 P + 新阻塞；入参加挂上轮复审）。Step 1 只做一次。上限默认 3 次（可配置到 10，见 shared/core-logic.md §6），超限汇报未解决问题。

## 硬性规则（主 agent）

- 每步等上一 subagent 返回后才进下一步；不可并行、不可跳步
- 主 agent 不得自己分析根因、写方案、改代码
- 传参只传原始问题/产物，禁止夹带倾向性结论
- Step 3 完成后必须立即进入 Step 4，不得中途停下汇报当"完成"

## 违规处理

越权修改文件：用 `baseline.diff`/备份精确回退 → 从违规点重走 → 记录到 `violations.log`。

更多细节（推荐矩阵、编号、循环、终止条件）见仓库 `shared/core-logic.md` 与 `shared/binding-recommendation.md`。