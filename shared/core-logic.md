# Harness 4-Step Method — 共享核心逻辑（平台无关）

> 本文件是四步法**唯一逻辑源**。Hermes 与 opencode 两个平台都引用本文件，任何逻辑优化只在这里改一次，双平台同步生效。
> 平台差异（CLI 调用方式、subagent 权限、队列、超时处理等）不写在这里，写在各平台的适配层。

## 1. 核心原则

**裁判不能当运动员。** 审查的人不能同时写代码；写代码的人不能决定改什么。每步必须**独立、互不干扰**，由不同 agent 以独立思维挑出彼此的逻辑死角。分权制衡才能发现问题。

## 2. 四步（严格顺序，不可跳步、不可并行）

| 步骤 | 角色 | 职责 | 硬性边界 |
|------|------|------|----------|
| Step 1 | 审查者 | 只找问题，输出问题清单（带编号） | 不写方案、不改代码 |
| Step 2 | 方案者 | 基于问题清单出修复方案（before/after） | 不改代码、不出无编号改动 |
| Step 3 | 执行者 | 严格按方案逐条修改 | 不分析根因、不扩大范围、不重构 |
| Step 4 | 复审者 | 打开实际代码核对 + 跑回归，输出评级 | 不自己修复 |

**Step 4 评级**: `通过` / `需调整`。`需调整` → 回到 Step 2（不回 Step 1；Step 1 只做一次）。

## 3. 问题与方案编号（追溯）

- 问题统一编号 `P-01, P-02…`
- 方案统一编号 `F-<P编号>`× 每个修复必须对应一个问题
- 全流程凭编号追溯，**禁止出现无编号内容**

## 4. 绑定语义（步骤 → 后端）

每个步骤绑定一个"后端"。后端分两类：

- **CLI 后端**：外部 agent CLI（codex / claude / kimi / mimo 等），通过 shell 调用真实二进制
- **Subagent 后端**：宿主平台内的独立子 agent（opencode 的 `harness-*`；Hermes 的 plugin/delegate 受控）

同一 CLI 可绑定不同步骤；**Step 4 必须与执行步骤（Step 3）使用不同模型族**，避免复审盲区。

绑定变更必须是**用户显式授权**，禁止执行者/审查者自行改绑定来绕过失败。

## 5. 按步骤特性推荐（详见 `shared/binding-recommendation.md`）

- Step 1 审查：深度读代码 → 推荐强分析模型（claude/codex；opencode 高智力模型）
- Step 2 方案：精确规划 → 强生成模型（claude/codex）
- Step 3 执行：精确改码、重成本 → 便宜快速模型（mimo）、或宿主内权限限定 subagent
- Step 4 复审：**与 Step 3 不同模型族** → codex / 或三选一错开

## 6. 循环机制

- 触发：Step 4 评级 `需调整` 或新阻塞问题
- 回退点：Step 2，**仅针对未通过的编号 + 新阻塞项**，禁止范围蔓延
- 上限：默认 3 次（Hermes 版可配到 10），超限停止并向用户报告全部未解决问题

## 7. 执行前基线（Step 3 前置）

- git 仓库：`git diff > baseline.diff`
- 非 git：复制相关文件到 `backup/`
- 目的：违规/出错时精确回退，不依赖盲目 `git revert HEAD`

## 8. 违规处理

任何角色越权（审查者改了文件 / 执行者自己决定改什么 / 跳步 / 并行）：
1. 用 `baseline.diff`/备份精确回退
2. 从违规点起重走流程
3. 记录到 `violations.log`（原因 + 责任人）

## 9. 终止条件

任一满足即终止：
- Step 4 评级 `通过`
- 循环达上限
- Step 1 零问题 → 报告"无需修复"

## 10. 平台适配层职责

| 能力 | Hermes 适配层 | opencode 适配层 |
|------|--------------|-----------------|
| 执行后端 | `run_cli.py` + `binding-lock.json` | `task` 调度 subagent + bash 调 CLI |
| 配置 | `~/.hermes/binding-lock.json` + `harness-config.yaml` | `opencode/SKILL.md` + subagent 文件 |
| 反绕过 | `plugin/four-step-enforcer` | subagent `permission: edit: deny`（系统级） |

任何平台**不得在本文件之外**复制逻辑实现；适配层只实现调用，不重新发明逻辑。