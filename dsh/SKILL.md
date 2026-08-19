---
name: harness-4step
description: "四步法 Harness（DeepSeek Harness 适配层）：审查→方案→执行→复审→循环直到通过。用独立 subagent 保证每步思维互不干扰、跳出逻辑死角；裁判不能当运动员。单一项目兼容 Hermes/opencode/DeepSeek Harness，共享逻辑见仓库 shared/。含四步法内部视觉兜底（vision-reviewer：mimo CLI + 视觉模型看图，shared/core-logic.md §11，DSH 与 opencode 支持、Hermes 自带视觉不触发）。Use when the user asks to run 四步法/4step/four-step harness/审查出方案执行复审/code review loop, or wants a bug fixed through separated audit-plan-implement-verify roles."
version: 13.0.23
---

# 四步法 Harness（DeepSeek Harness 适配层 v13.0.23 — DSH subagent 为主 + CLI 可选）

**逻辑源 = 仓库 `shared/core-logic.md`。** 本文件只做 DSH 落地：把共享逻辑映射到 DeepSeek Harness 的 subagent 与工具，不复制逻辑实现。逻辑有缺陷去改 shared/，本层只跟着更新引用。

**核心原则：裁判不能当运动员。** 每步独立互不干扰，不同 agent 以独立思维挑出彼此的逻辑死角。

## 与 Hermes/opencode 版的关系（单一项目）

| 维度 | Hermes 适配层 | opencode 适配层 | DSH 适配层（本文件） |
|------|--------------|-----------------|---------------------|
| 执行后端 | `run_cli.py` + `binding-lock.json`（每步绑外部 CLI） | bash/pwsh 调 CLI + Task 调度 subagent（`opencode-sub`） | **DSH `subagent` 工具为主（`dsh-sub`）** + 可选外部 CLI（经 pwsh 调 `opencode/scripts/` runner） |
| 反绕过 | `plugin/four-step-enforcer` | 绑定 CLI：prompt 只读前缀 + 统一经脚本调用 + 事后基线回退；绑定 opencode-sub：`permission: edit: deny` | 绑定 dsh-sub：提示词强制只读 + 统一经 `run_step.ps1` 分派 + 事后 `git diff > baseline.diff` 回退（DSH 无插件拦截，靠提示词+基线） |
| 队列/超时/拆分 | Hermes 专属机制 | 不复制，opencode 用任务清单+估算 | 不复制，用 `.harness/<task>/` 产物目录 + 任务清单（DSH 无 todo 队列插件） |

## 后端绑定（binding-lock.json 锁定；默认 step1/2/3/4=dsh-sub）

**绑定来源**：绑定持久化在 `~/.dsh/harness/binding-lock.json`（本机私有；模板在仓库 `dsh/binding-lock.json`；env `DSH_BINDING_LOCK` 可覆盖路径）。锁有效条件：`schema_version==1 && locked==true && bindings` 恰好覆盖 step1..step4——任一不满足即 fail-closed（Step 0 的 `dsh/scripts/manage_binding.ps1 -Check` 拒绝继续）。**绑定变更只能用 `dsh/scripts/manage_binding.ps1 -AuthorizeStep <step> -Agent <agent> -Authorization "<用户授权原文>"` 完成**（授权文本 ≥12 字符、写入 `authorization_log`、tmp 原子替换），禁止手改 lock 绕过。**脚本一律读 `~/.dsh/harness/binding-lock.json`（或 `DSH_BINDING_LOCK` 覆盖），不读仓库模板**；仓库 `dsh/binding-lock.json` 变更后须用 `manage_binding.ps1 -InstallFromRepo` 同步到本机副本再继续。

**当前绑定（用户显式授权："DSH 适配层默认全部步骤使用 DSH subagent"）**：

- step1 = dsh-sub（`harness-auditor`，只读）
- step2 = dsh-sub（`harness-planner`，只读）
- step3 = dsh-sub（`harness-implementer`，写文件）
- step4 = dsh-sub（`harness-verifier`，只读）
- step4 备用：可经 `manage_binding.ps1 -AuthorizeStep step4 -Agent codex` 切换到 codex CLI（外部独立模型族），仅当用户显式授权时切换。

**模型族（关键）**：`dsh-sub` 的模型族由 `binding-lock.json` 的 `models` 字段决定（step1/2/3 默认 `family: deepseek`，step4 必须配置为**其他族**如 `family: other` 或改用外部 CLI）。DSH `subagent` 工具创建 subagent 时支持 `provider`/`model` 覆盖——创建 step3 与 step4 的 subagent 时必须按此配置给不同模型，确保**Step 4 与 Step 3 不同模型族**（硬约束，`manage_binding.ps1 -Check` 强制校验）。若当前 DSH 环境只有单一模型族可用，必须如实向用户报告并停止，不得用"声明局限"代替不同族。

**超时/描述配置（可选，用户本机私有）**：`~/.dsh/harness/harness-config.json`（模板复用 `opencode/harness-config.example.json` 的结构，env `DSH_HARNESS_CONFIG` 覆盖）可覆盖每步 `timeout_seconds` 与 `description`；**不得含 agent 字段**（绑定只由 binding-lock.json 决定，对齐 Hermes v13.0.10 防双配置源漂移）。

## 角色与权限映射

| 步骤 | 角色 | 后端（binding-lock.json 锁定，默认） | 权限 | 职责 |
|------|------|------|------|------|
| 1 | 审查 | **dsh-sub**：`harness-auditor` | 只读（提示词强制；DSH 无权限隔离，越权靠事后基线回退） | 只找问题，不写方案（P 编号） |
| 2 | 方案 | **dsh-sub**：`harness-planner` | 只读（同上） | 只写计划（F-<P编号> + before/after） |
| 3 | 执行 | **dsh-sub**：`harness-implementer` | 写文件（write/edit/pwsh） | 严格按方案改，不分析 |
| 4 | 复审 | **dsh-sub**：`harness-verifier`（与 step3 不同模型族） | 只读（同上） | 独立验证（读实际代码 + 只读核对） |

- **后端开关可配置**：当前绑定全部为 dsh-sub。用户可经 `manage_binding.ps1 -AuthorizeStep <step> -Agent <claude|codex|mimo|kimi>` 显式授权切换到外部 CLI（经 pwsh 调 `opencode/scripts/` runner）。未授权时主 agent 不得因文档存在 CLI 分支而改走 CLI。
- step1-4 每次 subagent 调用都是**全新独立上下文**，只传问题描述/上一步产物，**不传主 agent 的分析结论**。
- step4 的 subagent 必须与 step3 不同模型族：创建时按 `models` 配置给不同 `provider`/`model`。

## dsh-sub 调用规范（step1/2/3/4 当前绑定）

每步经 `dsh/scripts/run_step.ps1 -Step step<N> -PromptFile <file> -WorkspaceDir <根> -OutDir <dir>` 分派。绑定=dsh-sub 时脚本输出 `BINDING=dsh-sub` + `SUBAGENT=<角色>` + 出口码 99，主 agent 必须消费该信号：

1. 读取 `dsh/agents/<角色>.md` 模板全文
2. 用 `subagent` 工具创建 subagent：`prompt` = 模板 + 具体任务事实（问题/方案/文件路径），`run_in_background: false`（四步闭环内串行）
3. 对 step3/step4，按 `binding-lock.json` 的 `models` 给 `provider`/`model` 覆盖（step4 ≠ step3 模型族）
4. 把 subagent 返回的结构化结果原样落为 `.harness/<task>/<step>-output.md` 或对应产物文件

```text
# step1 → .harness/<task>/step1-problems.md（P 编号）
# step2 → .harness/<task>/step2-plan.md（F-<P编号>）
# step3 → .harness/<task>/step3-changes.md
# step4 → .harness/<task>/step4-review.md（评级 通过/需调整）
```

- prompt 只含事实：step1=问题描述+文件路径；step2=问题清单（P 编号）；step3=F<编号> before/after 方案；step4=修改后文件绝对路径+原始问题清单。禁止夹带主 agent 倾向性结论。
- 只读 subagent（step1/2/4）提示词模板已含"禁止 write/edit/pwsh 写操作"；越权写文件靠 `git diff > baseline.diff` 事后回退。
- **拆分**：只读步骤超时（提示词模板含拆分指引）或失败 → 按 `core-logic.md §4b` 先拆分（生成无依赖子工作包，各子项独立走完整四步），拆分已达最小粒度才允许显式声明降级。不换绑定。

## CLI 调用规范（可选绑定：claude/codex/mimo/kimi）

仅当用户显式授权把某步绑定为外部 CLI 时使用。runner 脚本与 opencode 适配层共享（仓库 `opencode/scripts/`），经 pwsh 调用：

```powershell
# 绑定=claude（step1/2/3）：
& "opencode\scripts\run_claude_step12.ps1" -Step step1 -PromptFile ".harness\<task>\step1-prompt.txt" -WorkspaceDir "<仓库根>" -OutDir ".harness\<task>\step1"
# 绑定=codex（step4）：
& "opencode\scripts\run_codex_step4.ps1" -PromptFile ".harness\<task>\step4-prompt.txt" -WorkspaceDir "<仓库或工作目录>" -OutDir ".harness\<task>\step4"
# 绑定=mimo/kimi（step4 备用）：
& "opencode\scripts\run_mimo_step4.ps1" -PromptFile ".harness\<task>\step4-prompt.txt" -WorkspaceDir "<仓库或工作目录>" -OutDir ".harness\<task>\step4"
& "opencode\scripts\run_kimi_step4.ps1" -PromptFile ".harness\<task>\step4-prompt.txt" -WorkspaceDir "<仓库或工作目录>" -OutDir ".harness\<task>\step4"
```

- 主 agent 不得跳过 `dsh/scripts/run_step.ps1` 直接调 runner（`run_step.ps1` 是唯一分派入口，负责绑定校验）。
- 详细 CLI 语义（只读前缀、超时信号、认证处理）见 `opencode/SKILL.md#claude CLI 调用规范` 等章节，两适配层共用同一套 runner。

## 编排流程（主 agent）

1. **Step 0** 建工作区 `.harness/<task>/`，告知用户产物落盘位置；**必须执行** `dsh/scripts/manage_binding.ps1 -Check` 校验绑定（lock 存在且 locked、bindings 恰好 step1..step4、step3 与 step4 不同模型族），**失败即停**——校验失败即向用户报告并停止，不得继续后续步骤。
2. **Step 1** prompt（问题+文件路径）写入 `.harness/<task>/step1-prompt.txt` → 调 `run_step.ps1 -Step step1` → 消费 `BINDING=dsh-sub` 信号，用 `subagent` 调 `harness-auditor` → 产物落为 `step1-problems.md`（P 编号）。零问题则终止报告。
3. **Step 2** prompt（问题清单）写入 `.harness/<task>/step2-prompt.txt` → 调 `run_step.ps1 -Step step2` → 用 `subagent` 调 `harness-planner` → 产物落为 `step2-plan.md`（F-<P编号>）。只读步骤超时按 §4b 拆分优先：可拆则拆出无依赖子工作包，拆分已达最小粒度才允许显式声明降级。
4. **Step 2.5** 基线：git 仓库 `git diff > baseline.diff`；非 git 复制到 `backup/`。
5. **Step 3** prompt（F 方案清单）写入 `.harness/<task>/step3-prompt.txt` → 调 `run_step.ps1 -Step step3` → 用 `subagent` 调 `harness-implementer`（可写文件，按 models 配置模型）→ 产物落为 `step3-changes.md` + **`Step 3 验证状态` 块**（passed / blocked(<命令>/<原因>) / not-run(<原因>)，见 shared/core-logic.md §2b 验证门）。执行后对比基线验无方案外改动；**验证状态未达标（非 passed 且非显式 blocked/not-run）不得进入 Step 4 判通过**。
6. **Step 4** 入参 = 修改后代码绝对路径 + step1 问题清单 + **step3 验证状态** → 写 `step4-prompt.txt` → 调 `run_step.ps1 -Step step4` → 用 `subagent` 调 `harness-verifier`（**与 step3 不同模型族**）→ 读取 `step4-review.md`，评级 `通过`/`需调整`。step3 验证状态 = blocked/not-run → verifier 补跑只读回归（§2c）；= failed → 复跑确认细节，据此评级 `需调整`。
7. **循环**：`需调整` → 回 Step 2（只处理未通过的 P + 新阻塞；入参加挂上轮复审）。Step 1 只做一次。上限默认 3 次（可配置到 10，见 shared/core-logic.md §6），超限汇报未解决问题。

## 硬性规则（主 agent）

- 同一修复包内每步等上一 subagent 返回后才进下一步；不可跳步。独立的只读侦察、审查包和文件范围不重叠的完整修复包可以并行（并行侦察用 `run_in_background: true`）。
- 主 agent 不得自己分析根因、写方案、改代码
- 传参只传原始问题/产物，禁止夹带倾向性结论
- Step 3 完成后必须立即进入 Step 4，不得中途停下汇报当"完成"
- **Step 3 入口门禁**：任何 Step 3 操作前，必须先在用户可见消息中声明 `Step 3 implementation: dsh-sub (<模型>)` 或 CLI 名称

## 视觉审查（四步法内部视觉兜底，shared/core-logic.md §11）

> 定位：**这不是新步骤**，是四步法内部的**跨步视觉兜底**。当四步法某一步（step1 审截图 / step3 核对 UI 效果 / step4 对比 before-after）**需要视觉判断**、而该步绑定的后端（DSH subagent，默认无视觉）**无视觉**时，经本能力看图。Hermes **自带视觉识别，不触发本机制**；DSH 与 opencode 必须支持。

**机制**：主 agent 不自己看图（主模型无视觉）→ 经 `subagent` 工具调 `vision-reviewer` agent → 该 agent 经 pwsh 调共享 runner `opencode/scripts/run_vision_review.ps1`（从仓库根目录相对路径；DSH 侧经 `../../opencode/scripts/` 引用，与 CLI runner 共享模式一致）→ 脚本调 mimo CLI + 视觉模型（默认 `xiaomi/mimo-v2.5`）看图 → 返回结构化文本结论。

```text
主 agent（无视觉）──subagent──> vision-reviewer ──pwsh──> opencode/scripts/run_vision_review.ps1 ──mimo -f──> mimo-v2.5（视觉）
     ▲                                                                                                         │
     └──────── 返回结构化视觉结论（passed/needs-attention/blocked）→ 作为 step1/3/4 的输入佐证 ──────────────┘
```

**使用要点（主 agent）**：

- 触发：step1/step3/step4 需要视觉判断且后端无视觉时（见 shared/core-logic.md §11a 触发条件表）。**不是独立功能**，不脱离四步法单独用。
- 入参：图片文件路径（截图需先用脚本生成落盘，如 Playwright 截图）+ 审查重点（可选）+ **服务步骤**（step1/3/4）。
- 产物：`.harness/<task>/vision/vision-review.md`（mimo 原始结论）+ 结构化结论。
- 视觉模型：默认 `xiaomi/mimo-v2.5`（用户显式指定）；可换 `xiaomi/mimo-v2.5-pro`（经 `run_vision_review.ps1 -Model`）。
- 前提：本机已装并登录 mimo CLI（见 `references/mimo-cli-login.md`；`mimo providers whoami` 应输出 Provider: MiMo）。
- 依赖：mimo CLI 的 `-f/--file`（数组）可附加多张图片给视觉模型；`run_vision_review.ps1` 已封装。

**只读保证**：`run_vision_review.ps1` 与 `vision-reviewer` 均只读（不写目标代码，只写 `.harness/<task>/vision/` 产物）。视觉结论**不得虚构**：mimo 输出是唯一事实来源，打不开/超时/失败一律如实报告 `blocked`。

**边界**：视觉审查不改变绑定、不构成新步骤、不绕过 Step 4 与 Step 3 不同模型族约束（视觉模型仅看图，不替代 step4 的复审后端）；视觉结论与 step3 验证状态（§2b/§2c）是两条独立证据线（shared/core-logic.md §11c）。

**视觉 agent 模板**：`dsh/agents/vision-reviewer.md`（subagent 提示词模板，含调用规范与输出格式）。共享 runner 位于 `opencode/scripts/run_vision_review.ps1`（DSH 与 opencode 共用）。

## 违规处理

越权修改文件（含 step4 越权写文件）：用 `baseline.diff`/备份精确回退（step4 绑定外部 CLI 时经 `opencode/scripts/step4_readonly_guard.ps1` 快照比对自动回退，绑定 dsh-sub 时提示词强制 + 事后快照核对）→ 从违规点重走 → **强制记录**到 `docs/violations.log`（`manage_binding.ps1 -RecordViolation`，禁止仅口头说明）。违规类别 A/B/C/D/E 见 shared/core-logic.md §8。

更多细节（推荐矩阵、编号、循环、终止条件）见仓库 `shared/core-logic.md` 与 `shared/binding-recommendation.md`。

## 安装

见 `dsh/README.md`。核心步骤：

1. 复制 `dsh/SKILL.md` → `~/.dsh/skills/harness-4step/SKILL.md`（或项目 `.dsh/skills/harness-4step/SKILL.md`）
2. 复制 `dsh/scripts/` 到 skill 目录（`manage_binding.ps1`、`run_step.ps1`）
3. `manage_binding.ps1 -InstallFromRepo` 同步绑定锁 → `manage_binding.ps1 -Check` 校验
4. 用 DSH 打开**仓库根目录**作为工作区（或设置 `HARNESS_SHARED_DIR` 指向仓库 `shared/`），使 subagent 能读共享逻辑
5. 视觉审查（shared/core-logic.md §11）依赖共享 runner `opencode/scripts/run_vision_review.ps1`：从仓库根目录运行时用相对路径 `opencode/scripts/run_vision_review.ps1`（与 CLI runner 共享模式一致）；单独复制脚本时一并复制该文件即可（mimo CLI 需已装并登录，见 `references/mimo-cli-login.md`）

## 版本历史

- v13.0.23 (2026-08-19): 三平台版本对齐至 13.0.23（opencode 侧违规7 修复：step4 支持 opencode-sub/harness-verifier + mimo runner 根因修复 + UTF-8 stdin 字节直写）。版本号 13.0.22 → 13.0.23。
- v13.0.22 (2026-08-15): 视觉审查**封装进四步法**（shared/core-logic.md §11）——由"独立能力"改为"四步法内部跨步视觉兜底"：当 step1/step3/step4 需要视觉判断且该步后端无视觉时触发，视觉结论作为该步输入佐证；共享 runner 移至 `opencode/scripts/run_vision_review.ps1`（DSH 经 `../../opencode/scripts/` 引用，与 CLI runner 共享模式一致）；vision-reviewer 模板更新定位与调用路径。opencode 适配层同步支持；Hermes 自带视觉不触发。版本号 13.0.21 → 13.0.22。
- v13.0.21 (2026-08-15): 新增**独立视觉审查能力**（不属于四步法）——`dsh/scripts/run_vision_review.ps1`（经 mimo CLI `-f` 附加多图给视觉模型 `xiaomi/mimo-v2.5` 看图，输出 `vision-review.md`）+ `dsh/agents/vision-reviewer.md`（独立 subagent 模板）。主模型无视觉时经此调用其他模型看图，与四步法解耦、可随时单独调用。版本号 13.0.20 → 13.0.21。
- v13.0.20 (2026-08-14): 同步 shared/core-logic.md §2b/§2c Step 3 验证门——implementer 提示词新增 `Step 3 验证状态` 输出与验证要求；verifier 提示词读取 step3 验证状态并决定兜底只读回归；编排流程 Step 3/4 纳入验证门；违规处理对齐 §8 类别 A-E。版本号 13.0.19 → 13.0.20。
- v13.0.19 (2026-08-14): 新增 DeepSeek Harness (DSH) 适配层——`dsh/SKILL.md` + `dsh/agents/`（6 个 subagent 提示词模板）+ `dsh/scripts/`（manage_binding.ps1 / run_step.ps1）+ `dsh/binding-lock.json`。默认全部步骤绑定 `dsh-sub`（DSH subagent），经 `run_step.ps1` 分派输出 `BINDING=dsh-sub` 信号后由主 agent 用 `subagent` 工具调度；可选绑定外部 CLI（claude/codex/mimo/kimi，复用 opencode/scripts runner）。模型族约束：`models` 字段决定 dsh-sub 的族，step4 必须与 step3 不同族。版本号 13.0.18 → 13.0.19。
