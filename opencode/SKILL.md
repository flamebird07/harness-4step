---
name: four-step-harness
description: "四步法 Harness + Loops 循环机制：审查→方案→执行→复审→循环直到通过。用独立 subagent 保证每步思维互不干扰、跳出逻辑死角；裁判不能当运动员。单一项目兼容 Hermes/opencode，共享逻辑见仓库 shared/。Use when the user asks to run 四步法/4step/four-step harness/审查出方案执行复审/code review loop, or wants a bug fixed through separated audit-plan-implement-verify roles."
version: 13.0.16
---

# 四步法 Harness（opencode 适配层）

**逻辑源 = 仓库 `shared/core-logic.md`。** 本文件只做 opencode 落地：把共享逻辑映射到 opencode 的 subagent 与工具，不复制逻辑实现。逻辑有缺陷去改 shared/，本层只跟着更新引用。

**核心原则：裁判不能当运动员。** 每步独立互不干扰，不同 agent 以独立思维挑出彼此的逻辑死角。

## 与 Hermes 版的关系（单一项目）

| 维度 | Hermes 适配层 | opencode 适配层（本文件） |
|------|--------------|---------------------------|
| 执行后端 | `run_cli.py` + `binding-lock.json`（每步绑外部 CLI） | bash 调 claude CLI（step1-3）+ codex CLI（step4），绑定由 `binding-lock.json` + `manage_binding.ps1` 管理 |
| 反绕过 | `plugin/four-step-enforcer` | 绑定 CLI：prompt 只读前缀 + 统一经 `scripts/` 脚本调用 + 事后基线回退；绑定 opencode-sub：subagent `permission: edit: deny` |
| 队列/超时/拆分 | Hermes 专属机制 | 不复制，opencode 用任务清单+估算即可 |

## 后端绑定（binding-lock.json 锁定；默认 step1/2/3=claude CLI）

**绑定来源**：绑定持久化在 `~/.config/opencode/harness/binding-lock.json`（本机私有；模板在仓库 `opencode/binding-lock.json`；env `OPCODE_BINDING_LOCK` 可覆盖路径）。锁有效条件：`schema_version==1 && locked==true && bindings` 恰好覆盖 step1..step4——任一不满足即 fail-closed（Step 0 的 `manage_binding.ps1 -Check` 拒绝继续）。**绑定变更只能用 `opencode/scripts/manage_binding.ps1 -AuthorizeStep <step> -Agent <agent> -Authorization "<用户授权原文>"` 完成**（授权文本 ≥12 字符、写入 `authorization_log`、tmp 原子替换），禁止手改 lock 绕过。

**当前绑定（用户显式授权："step1/2/3 用 Claude code cli"）**：
- step1 = claude CLI（`run_claude_step12.ps1 -Step step1`，只读）
- step2 = claude CLI（`run_claude_step12.ps1 -Step step2`，只读）
- step3 = claude CLI（`run_claude_step12.ps1 -Step step3`，写文件，带 `--dangerously-skip-permissions`）
- step4 = codex CLI（外部独立模型族，`run_codex_step4.ps1`）
- step4 备用：mimo CLI（`run_mimo_step4.ps1`），仅当 codex 认证失效且用户显式授权时切换，经 `manage_binding.ps1 -AuthorizeStep step4 -Agent mimo` 记录；`harness-verifier` 作为 *CLI 备用*的兜底路径已废弃（双兜底冲突，见 agents/harness-verifier.md）；但 `opencode-sub` 绑定分派到 `harness-verifier` 的路径仍受支持（经 run_step.ps1 输出 BINDING=opencode-sub 后由主 agent 调度）

**核心约束（不可违反，`manage_binding.ps1 -Check` 强制校验）**：Step 4 必须与 Step 3 不同模型族（当前 step3=claude、step4=codex，不同族；任何授权变更写入前立即校验，不满足则拒绝写入）。

**超时/描述配置（可选，用户本机私有）**：`~/.config/opencode/harness/harness-config.json`（模板 `opencode/harness-config.example.json`，env `OPCODE_HARNESS_CONFIG` 覆盖）可覆盖每步 `timeout_seconds` 与 `description`；**不得含 agent 字段**（绑定只由 binding-lock.json 决定，对齐 Hermes v13.0.10 防双配置源漂移）。编排时以 `manage_binding.ps1 -ShowBindings` 输出的 timeout 为准，传给各 ps1 的 `-TimeoutSeconds`。

## 角色与权限映射

| 步骤 | 角色 | 后端（binding-lock.json 锁定，默认） | 权限 | 职责 |
|------|------|------|------|------|
| 1 | 审查 | **claude CLI**（`run_claude_step12.ps1 -Step step1`） | 只读（无权限跳过） | 只找问题，不写方案（P 编号） |
| 2 | 方案 | **claude CLI**（`run_claude_step12.ps1 -Step step2`） | 只读（无权限跳过） | 只写计划（F-<P编号> + before/after） |
| 3 | 执行 | **claude CLI**（`run_claude_step12.ps1 -Step step3`） | 写文件（--dangerously-skip-permissions） | 严格按方案改，不分析 |
| 4 | 复审 | **codex CLI**（playbook: `opencode/scripts/run_codex_step4.ps1`） | 脚本注入只读 prompt 前缀；无系统级隔离（opencode 无插件拦截），越权只能事后基线回退 | 独立验证（读实际代码 + 只读核对） |

- 备用后端：绑定可经用户授权（`manage_binding.ps1 -AuthorizeStep`）切回 `opencode-sub`（`harness-auditor`/`harness-planner`/`harness-implementer` subagent；edit: deny/deny/allow 由 frontmatter 保证）。
- step1-3 每次 CLI 调用都是**全新独立上下文**，只传问题描述/上一步产物，**不传主 agent 的分析结论**。
- step4 由主 agent 用 bash 调 codex CLI，独立进程独立上下文。

## claude CLI 调用规范（step1/2/3 当前绑定）

```powershell
& "opencode\scripts\run_claude_step12.ps1" -Step step1 -PromptFile ".harness\<task>\step1-prompt.txt" -WorkspaceDir "<仓库根>" -OutDir ".harness\<task>\step1"
& "opencode\scripts\run_claude_step12.ps1" -Step step2 -PromptFile ".harness\<task>\step2-prompt.txt" -WorkspaceDir "<仓库根>" -OutDir ".harness\<task>\step2"
& "opencode\scripts\run_claude_step12.ps1" -Step step3 -PromptFile ".harness\<task>\step3-prompt.txt" -WorkspaceDir "<仓库根>" -OutDir ".harness\<task>\step3"
# 产物：<OutDir>/claude_raw.txt（原始输出）、<OutDir>/<Step>-output.md（过滤后的模型正文 = 该步产物）
```

- `$Step` 仅接受 step1/step2/step3；脚本按步骤注入保护前缀（step1/2 只读、step3 禁止自跑测试），step3 自动带 `--dangerously-skip-permissions`（写文件），step1/2 不带。
- prompt 只含事实：step1=问题描述+文件路径；step2=问题清单（P 编号）；step3=F<编号> before/after 方案；禁止夹带主 agent 倾向性结论。
- 超时默认 step1/2=120s、step3=300s（可经 harness-config.json 覆盖，见"后端绑定"节的配置说明）。
- 失败信号：`EXIT_CODE=-3`=参数错误（修 prompt 后重跑）；`-2`=超时（看保留的部分输出判断拆分/精简）；`-1`=无 agent_message，重试一次；仍失败则记录后向用户汇报。

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
- prompt 必须包含：step1 原始问题清单（P 编号）+ 修改后文件绝对路径 + 明确要求"打开实际文件核对、只读核对（Get-Content/rg/git diff），禁止写文件/测试、逐条评级、输出总体 通过/需调整"。
- 脚本会自动向 prompt 注入 step4 只读前缀（静态只读复审、禁止执行测试）——只读约束靠 prompt 落地（codex 沙箱为 danger-full-access，无系统级隔离），越权写文件靠 baseline.diff 事后回退。
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

- 仅当 codex 认证失效且用户显式授权切 mimo 时使用（经 `manage_binding.ps1 -AuthorizeStep step4 -Agent mimo` 记录）。模型默认 `xiaomi/mimo-v2.5-pro`；脚本已内置 `--print-logs`、step4 只读前缀与 mimo 防虚构前缀、`-f` 文件传参（对齐 Hermes run_cli.py：避免超长 prompt 命令行截断）。

## kimi CLI 调用规范（step4 备用，-p 位置参数）

```powershell
& "opencode\scripts\run_kimi_step4.ps1" `
    -PromptFile ".harness\<task>\step4-prompt.txt" `
    -WorkspaceDir "<仓库或工作目录>" `
    -OutDir ".harness\<task>\step4"
# 产物：step4/kimi_raw.txt（原始输出）、step4/step4-review.md
```

- **传参方式**：实现为 `kimi -p <prompt> --add-dir <workspace>` **位置参数**（kimi 不支持 stdin，与 run_claude 的 stdin 管道不同，也与 run_mimo 的 `-f` 文件传参不同）。
- **截断风险**：`-p` 命令行参数有 **8191 字符**上限，超长 prompt 会被截断。若 prompt 超长应精简（或改经 run_mimo_step4.ps1 的 `-f` 文件模式），不要在 `-p` 里塞超长文本。

## 编排流程（主 agent 用 Task 工具 + run_step.ps1 统一分派）

### 动态拆分前置规则

默认使用 `harness-orchestrator` 作为主代理。它先判断任务是否需要委派：单一、明确、低风险任务可直接完成；有多个独立未知点、跨模块影响或需求歧义时，先把代码事实问题拆成互不依赖的工作包，并行调用 `harness-explorer`。对边界完全独立的模块，可并行调用 `harness-auditor`，但每个审查包必须拥有独立的 `.harness/<task>` 产物目录。

同一可写工作包仍必须走下面的严格四步闭环。只有文件范围、验收条件和依赖都不重叠的工作包才可并行实施；多个执行 agent 禁止修改同一文件或同一逻辑区域。完整的路由表和安装方式见 `opencode/DYNAMIC-DELEGATION.md`。

每步统一经 `opencode/scripts/run_step.ps1 -Step step<N> -PromptFile <file> -WorkspaceDir <根> -OutDir <dir>` 分派：脚本读 `binding-lock.json` 取该步绑定，按绑定调对应 runner（claude/codex/mimo/kimi）。若脚本输出 `BINDING=opencode-sub` 且 `EXIT_CODE=99`，主 agent 必须改用 Task 工具调度对应 subagent（按 `SUBAGENT` 字段：step1→`harness-auditor`、step2→`harness-planner`、step3→`harness-implementer`、step4→`harness-verifier`），未消费该信号视为本步未完成；其余绑定由脚本直调 CLI runner。

1. **Step 0** 建工作区 `.harness/<task>/`，告知用户产物落盘位置；先跑 `opencode/scripts/manage_binding.ps1 -Check` 校验绑定（lock 存在且 locked、bindings 恰好 step1..step4、step4 与 step3 不同模型族），校验失败即停止并向用户报告，不得继续后续步骤。
2. **Step 1** prompt（问题+文件路径）写入 `.harness/<task>/step1-prompt.txt` → 调 `run_step.ps1 -Step step1` → 把分派产物（CLI runner 为 `step1/step1-output.md`；subagent 为 Task 返回）落为 `step1-problems.md`（P 编号）。零问题则终止报告。
3. **Step 2** prompt（问题清单）写入 `.harness/<task>/step2-prompt.txt` → 调 `run_step.ps1 -Step step2` → 把分派产物落为 `step2-plan.md`（F-<P编号>）。
4. **Step 2.5** 基线：git 仓库 `git diff > baseline.diff`；非 git 复制到 `backup/`。
5. **Step 3** prompt（F 方案清单）写入 `.harness/<task>/step3-prompt.txt` → 调 `run_step.ps1 -Step step3` → 产物落为 `step3-changes.md`。执行后对比基线验无方案外改动。
6. **Step 4** 入参 = 修改后代码绝对路径 + step1 问题清单 → 写 `step4-prompt.txt` → 调 `run_step.ps1 -Step step4` → 读取 `step4/step4-review.md`，评级 `通过`/`需调整`。
7. **循环**：`需调整` → 回 Step 2（只处理未通过的 P + 新阻塞；入参加挂上轮复审）。Step 1 只做一次。上限默认 3 次（可配置到 10，见 shared/core-logic.md §6），超限汇报未解决问题。

## 硬性规则（主 agent）

- 同一修复包内每步等上一 subagent 返回后才进下一步；不可跳步。独立的只读侦察、审查包和文件范围不重叠的完整修复包可以并行
- 主 agent 不得自己分析根因、写方案、改代码
- 传参只传原始问题/产物，禁止夹带倾向性结论
- Step 3 完成后必须立即进入 Step 4，不得中途停下汇报当"完成"

## 违规处理

越权修改文件：用 `baseline.diff`/备份精确回退 → 从违规点重走 → 记录到 `violations.log`。

更多细节（推荐矩阵、编号、循环、终止条件）见仓库 `shared/core-logic.md` 与 `shared/binding-recommendation.md`。

## 版本历史

- v13.0.16 (2026-08-13): 融合后加固——run_step.ps1 claude 分支 step-aware 超时（step3→300、step1/2→120）；codex/mimo/kimi step4 回退 300→180；opencode-sub 改权威分派契约（输出 BINDING/STEP/SUBAGENT + 出口码 99，未消费视为未完成）；harness-orchestrator "直接处理"限定只读；DYNAMIC-DELEGATION 新增"与 CLI 绑定分派（线B）的关系" + 调度表只读限定；verifier 兜底措辞澄清。版本号 13.0.15 → 13.0.16。
- v13.0.15 (2026-08-13): 绑定 fail-closed 加固——manage_binding.ps1 / run_step.ps1 受支持 agent 统一为 claude/codex/mimo/kimi/opencode-sub（去 gemini）；run_step.ps1 分派前校验 schema/locked/完整绑定/受支持 agent/step3≠step4 模型族；manage_binding.ps1 补 step1/2 受支持校验；run_codex_step4.ps1 用 `-C` 传 WorkspaceDir 给 codex exec；kimi 文档对齐（-p 位置参数 + 8191 截断）；README 安装清单补 run_step.ps1 / run_kimi_step4.ps1。版本号 13.0.14 → 13.0.15。
- v13.0.14 (2026-08-13): 编排动态分派——新增统一入口 `opencode/scripts/run_step.ps1 -Step step1..4`，读 binding-lock.json 按绑定分派到对应 runner，opencode-sub 绑定输出 `BINDING=opencode-sub` 信号改走对应 subagent；新增 `run_kimi_step4.ps1`（kimi 用 `-p` 位置参数传 prompt，**非 stdin**，有 8191 命令行截断风险）；step4 只读前缀裁决为允许只读核对（禁止写文件/测试）；run_claude_step12.ps1 修复 Start-Job stdin UTF-8 + step1/2/3 加 `--add-dir`。
- v13.0.13 (2026-08-13): 绑定升级——新增 `opencode/binding-lock.json` 持久化 + `opencode/scripts/manage_binding.ps1`（-Check 校验 / -AuthorizeStep 显式授权 / authorization_log / tmp 原子写 / step4≠step3 模型族强制）；step1/2/3 默认绑定 Claude Code CLI（用户显式授权），step4=codex 保持不同模型族；mimo 脚本改 `-f` 文件模式 + `--print-logs` + 只读/防虚构前缀；三个 ps1 统一超时部分输出与失败信号（EXIT_CODE=-3）；run_claude_step12.ps1 修复 step 语义/去掉 ANTHROPIC_* 环境变量 hack。
