---
name: four-step-harness
description: "四步法 Harness + Loops 循环机制：审查→方案→执行→复审→循环直到通过。用独立 subagent 保证每步思维互不干扰、跳出逻辑死角；裁判不能当运动员。单一项目兼容 Hermes/opencode，共享逻辑见仓库 shared/。最小集 v13.0.13 引入脚本 orchestrator（run_step.ps1） + binding-lock.json fail-closed 校验 + 5 runner evidence.json 写盘 + BLOCKED_SPLIT_LIMIT 壁垒 + Pitfalls 节。Use when the user asks to run 四步法/4step/four-step harness/审查出方案执行复审/code review loop, or wants a bug fixed through separated audit-plan-implement-verify roles."
version: 13.0.26
---

# 四步法 Harness（opencode 适配层）v13.0.26

**逻辑源 = 仓库 `shared/core-logic.md`。** 本文件只做 opencode 落地：把共享逻辑映射到 opencode 的 subagent 与工具，不复制逻辑实现。逻辑有缺陷去改 shared/，本层只跟着更新引用。

**核心原则：裁判不能当运动员。** 每步独立互不干扰，不同 agent 以独立思维挑出彼此的逻辑死角。

## 与 Hermes 版的关系（单一项目）

| 维度 | Hermes 适配层 | opencode 适配层（本文件） |
|------|--------------|---------------------------|
| 执行后端 | `run_cli.py` + `binding-lock.json`（每步绑外部 CLI） | `scripts/run_step.ps1` 按 binding 路由 CLI；仅已验证的 step4/opencode-sub 以 99 移交 orchestrator |
| 反绕过 | `plugin/four-step-enforcer` | subagent `permission: edit: deny`（系统级）+ **step4 快照强制（Save@step4前 → Assert@step4后，shared/core-logic.md §8b，CLI 由 run_step.ps1 自动、opencode-sub 由编排层 assert，未通过即 EXIT_CODE=4 + 自动回退）** |
| 队列/超时/拆分 | Hermes 专属机制 | opencode 经 `opencode/scripts/run_step.ps1` 实现超时拆分：`MaxSplitDepth=3`/`MaxAttempts=3`/`最小粒度<4行`/`EXIT_CODE=3 blocked_split_limit`，见 `shared/core-logic.md §6.1` |

## 后端绑定（当前锁定配置）

> 以下为 `opencode/binding-lock.json` 当前完整快照（由 orchestrator 写入，每次绑定变更后自动同步）。

```json
{
  "bindings": {
    "step1": { "agent": "claude", "model": null, "permission_mode": "default" },
    "step2": { "agent": "claude", "model": null, "permission_mode": "default" },
    "step3": { "agent": "claude", "model": null, "permission_mode": "bypassPermissions" },
    "step4": { "agent": "opencode-sub", "model": null, "permission_mode": "default" }
  },
  "constraints": {
    "step4_must_differ_from_step3_family": true
  },
  "authorization_log": [ ... ]
}
```

> **注意**：该小节应为自动生成的只读快照，禁止手动编辑。若发现内容与 `binding-lock.json` 不一致，应触发 `violations.log` 记录。

## 角色与权限映射

| 步骤 | 角色 | 后端 | 权限 | 职责 |
|------|------|------|------|------|
| 1 | 审查 | `harness-auditor` subagent | edit: deny | 只找问题，不写方案（P 编号） |
| 2 | 方案 | `harness-planner` subagent | edit: deny | 只写计划（F-<P编号> + before/after） |
| 3 | 执行 | **mimo CLI**（`opencode/scripts/run_mimo_step3.ps1`，edit: allow） | 严格按方案改，不分析 |
| 4 | 复审 | **`harness-verifier` subagent**（opencode-sub，`opencode/agents/harness-verifier.md`） | edit: deny（只读） | 独立验证（读实际代码 + 跑回归） |

- step1-3 每次 Task 调用都是**全新独立上下文**，只传问题描述/上一步产物，**不传主 agent 的分析结论**。
- step4 由主 agent 用 Task 调 `harness-verifier` subagent（binding=opencode-sub），独立上下文；mimo/codex CLI 为备用路径。

## codex CLI 调用规范（step4 备用路径，仅 mimo 认证失效且用户授权时使用）

```powershell
# 把复审 prompt 写入 .harness/<task>/step4-prompt.txt 后执行（V10 强制：bash 120s 截断 → 必须 timeout=300000 + Tee-Object 透传）：
bash --timeout 300000 -c "pwsh -NoProfile -File opencode/scripts/run_codex_step4.ps1 -PromptFile '.harness/<task>/step4-prompt.txt' -WorkspaceDir '<仓库根>' -OutDir '.harness/<task>/step4' | Tee-Object -FilePath '.harness/<task>/step4/run.log'"
# 产物：step4/codex_raw.jsonl（原始输出）、step4/step4-review.md（提取的 agent_message + 环境信息）
# 路径说明：仓库内用 opencode/ 相对路径；按 opencode/README.md 安装后脚本位于 <skill 目录>/scripts/，
# 调用对应改为 bash --timeout 300000 -c "pwsh -File \"<skill 目录>/scripts/run_codex_step4.ps1\" -PromptFile ... | Tee-Object ..."
```

- **连接前提**：脚本按 PATH 解析 `codex`；PATH 无 codex 时回退 `CODEX_HOME\.sandbox-bin\codex.exe`（`CODEX_HOME` 默认 `~/.ccsc/codex-mimo`，可用环境变量覆盖）。若认证失效会 401，需用户 `codex login`（或在 Codex 应用重新登录）。
- **只读强制（不可违反）**：`run_codex_step4.ps1` 用 `--sandbox read-only` 启动 codex，**blocked 一切写操作**（apply_patch / Edit / Write / 写文件命令）。step4 是复审者，只能读验证，绝不允许改文件。若 codex 尝试写文件会被 sandbox 拒绝并报错——这是预期行为，不是故障。
- prompt 必须包含：step1 原始问题清单（P 编号）+ 修改后文件绝对路径 + 明确要求"打开实际文件核对、能跑回归就跑、逐条评级、输出总体 通过/需调整"。
- 传给 codex 的 prompt 只含事实（问题 + 文件路径），不含主 agent 的倾向性结论。
- 若输出含 `NO agent_message` 或 `EXIT_CODE=-1`，重试一次；仍失败则记录后向用户汇报。

## mimo CLI 调用规范（step3 执行，当前绑定）

```powershell
# 把执行 prompt 写入 .harness/<task>/step3-prompt.txt 后执行（V10 强制：bash 120s 截断 → 必须 timeout=300000 + Tee-Object 透传）：
bash --timeout 300000 -c "pwsh -NoProfile -File opencode/scripts/run_mimo_step3.ps1 -PromptFile '.harness/<task>/step3-prompt.txt' -WorkspaceDir '<仓库根>' -OutDir '.harness/<task>/step3' | Tee-Object -FilePath '.harness/<task>/step3/run.log'"
# 产物：step3/mimo_step3_raw.txt（原始输出）、step3/step3-output.md
# 路径说明：仓库内用 opencode/ 相对路径；按 opencode/README.md 安装后脚本位于 <skill 目录>/scripts/，
# 调用对应改为 bash --timeout 300000 -c "pwsh -File \"<skill 目录>/scripts/run_mimo_step3.ps1\" -PromptFile ... | Tee-Object ..."
```

- **长 prompt 兼容性（关键）**：脚本用 **stdin 管道** 把 prompt 喂给 mimo，而非 argv 位置参数。Windows 上长 prompt 会破坏 mimo 的 argv 解析（与 kimi 相同），短 prompt 正常、长 prompt 报错即此问题。**不要改成 `--file`**：mimo 的 `-f/--file` 是贪婪的附件文件路径数组，会吞掉后续参数并报 `File not found`，不能用来传 prompt。
- 模型默认 `xiaomi/mimo-v2.5-pro`。
- 执行身份：`--dangerously-skip-permissions` 允许改文件（step3 职责）。

## mimo CLI 调用规范（step4 备用）

```powershell
# V10 强制：bash 120s 截断 → 必须 timeout=300000 + Tee-Object 透传
bash --timeout 300000 -c "pwsh -NoProfile -File opencode/scripts/run_mimo_step4.ps1 -PromptFile '.harness/<task>/step4-prompt.txt' -WorkspaceDir '<仓库根>' -OutDir '.harness/<task>/step4' | Tee-Object -FilePath '.harness/<task>/step4/run.log'"
# 产物：step4/mimo_raw.txt（原始输出）、step4/step4-review.md
# 路径说明：仓库内用 opencode/ 相对路径；按 opencode/README.md 安装后脚本位于 <skill 目录>/scripts/，
# 调用对应改为 bash --timeout 300000 -c "pwsh -File \"<skill 目录>/scripts/run_mimo_step4.ps1\" -PromptFile ... | Tee-Object ..."
```

- 仅当 codex 认证失效且用户显式授权切 mimo 时使用。模型默认 `xiaomi/mimo-v2.5-pro`。

## V10 强制调用约定（bash 120s 截断 → 300000+Tee-Object 透传）

> **根因**：opencode bash 工具默认 `timeout=120000` 且输出超 2000 行/51200 字节截断；各 runner 末尾才集中 `Write-Output EXIT_CODE/ELAPSED/RAW/OUTPUT`，120s 前无增量落盘，导致超时 `-2` 与耗时证据被吞没，拆分链无法触发。

**强制**：所有 `bash` 调 `run_step.ps1 / manage_binding.ps1 / run_claude_step12.ps1 / run_mimo_step*.ps1 / run_codex_step4.ps1 / run_vision_review.ps1` 必须：

```powershell
# PowerShell 侧用 Tee-Object 实时落盘，bash 侧用 timeout=300000
bash --timeout 300000 -c "pwsh -NoProfile -File opencode/scripts/run_step.ps1 -Step step1 -PromptFile '.harness/<task>/step1-prompt.txt' -WorkspaceDir '<仓库根>' -OutDir '.harness/<task>/step1' | Tee-Object -FilePath '.harness/<task>/step1/run.log'"
# manage_binding 校验同理：
bash --timeout 300000 -c "pwsh -NoProfile -File opencode/scripts/manage_binding.ps1 -Check | Tee-Object -FilePath '.harness/<task>/binding-check.log'"
```
* `timeout=300000` 保证 120s 不截断；`Tee-Object` 保证 EXIT/ELAPSED/RAW 实时透传到控制台与文件，超时 `-2` 可被上游捕获并立即走 `run_step.ps1:140 MaxSplitDepth=3` 拆分（V11），而非“停下汇报”。*

## Pitfalls（实施踩坑备忘）

### Pitfall 1 · 拆分递归爆炸
- **现象**：某步 CLI 超时后自动拆分 prompt 重跑，子项仍超时再拆，无限递归耗尽资源。
- **规则**：受 `MaxSplitDepth=3`、`MaxAttempts=3` 壁垒约束，最小粒度=单文件（prompt 行数 < 4 不再拆，对应 `run_step.ps1:171`）；触壁垒即写 `status="blocked_split_limit"`、进程以 `EXIT_CODE=3` 退出，不再递归（详见 `shared/core-logic.md` §6.1）。**V11 立即拆分**：`EXIT_CODE=-2` 且 `prompt 行数≥4` 且 `attempt<MaxSplitDepth` → 立即二分重跑，深度达 3 才 `blocked_split_limit/EXIT_CODE=3`，不得停下汇报。
- **触发**：某步 CLI 超时（`EXIT_CODE=-2`）且当前 prompt 仍可拆。

### Pitfall 2 · 借拆分换模型族绕过绑定
- **现象**：执行者借"拆分重跑"之名改用另一模型族，规避"Step 4 必须与 Step 3 不同模型族 / 绑定变更需显式授权"的约束。
- **规则**：拆分重跑沿用原步绑定——orchestrator 从 `binding-lock.json` 读 `bindings.$Step`，禁止借拆分换模型族；换绑定只能编辑 `binding-lock.json` 并在 `authorization_log` 追加条目。
- **触发**：超时拆分路径被触发时。

### Pitfall 3 · evidence.json 缺失或被覆盖
- **现象**：runner 只写 `stepN-output.md` 不留机器可校验证据，或控制台输出覆盖 evidence 导致失败无法追溯。
- **规则**：每个 runner 在 `Out-File $msgFile` 之后、`Write-Output` 之前追加写 `evidence.json`（7 字段 + `binding_snapshot`），**不替换**原有 `stepN-output.md` 与 `EXIT_CODE/ELAPSED/RAW/OUTPUT` 控制台行。
- **触发**：任意 runner 正常或异常退出前。

## 编排流程（唯一入口：`scripts/run_step.ps1`）

`step1` 至 `step4` 的唯一启动入口是 `scripts/run_step.ps1`。主 agent 不得直接调用 `Task`、任一 `harness-*` subagent 或任一独立 runner；必须先由该脚本完成 Step 0 的 lock/binding 校验，再按当前 `bindings.<step>` 路由。缺失、未锁定、非法或无法解析的 lock 一律 fail-closed，且不得启动 CLI 或 subagent。

1. **Step 0** 建工作区 `.harness/<task>/`，告知用户产物落盘位置。**V10 强制**：`bash --timeout 300000 -c "pwsh -File opencode/scripts/manage_binding.ps1 -Check | Tee-Object -FilePath .harness/<task>/binding-check.log"` 校验；`locked` 必须 `true`、step3 与 step4 模型族必须不同（`constraints.step4_must_differ_from_step3_family`）；任一不满足 orchestrator fail-closed 拒绝启动。绑定变更通过编辑 `binding-lock.json` 并在 `authorization_log` 追加条目实现。
2. **Step 1** `harness-auditor`：`bash --timeout 300000 -c "pwsh -File opencode/scripts/run_step.ps1 -Step step1 ... | Tee-Object -FilePath .harness/<task>/step1/run.log"` → `step1-problems.md`（P 编号）。只读步骤超时 `EXIT_CODE=-2` → 立即走 `run_step.ps1:140 MaxSplitDepth=3` 拆分（`MaxAttempts=3`/`最小粒度<4行`/`EXIT_CODE=3 blocked_split_limit`），不得停下汇报。零问题则终止。
3. **Step 2** `harness-planner`：同上 `bash --timeout 300000 … | Tee-Object` → `step2-plan.md`（F-<P编号>），超时同 V11 立即拆分。
4. **Step 2.5** 基线：git 仓库 `git diff > baseline.diff`；非 git 复制到 `backup/`。
5. **Step 3** 执行：把方案写入 `step3-prompt.txt` → `bash --timeout 300000 -c "pwsh -File opencode/scripts/run_step.ps1 -Step step3 ... | Tee-Object -FilePath .harness/<task>/step3/run.log"` → 读 `step3/step3-output.md`。执行后对比基线验无方案外改动。
6. **Step 4** **`harness-verifier` subagent（opencode-sub）**：`bash --timeout 300000 -c "pwsh -File opencode/scripts/run_step.ps1 -Step step4 ... | Tee-Object -FilePath .harness/<task>/step4/run.log"`（Save@step4前）→ Task 调 `harness-verifier` → 编排层 `Assert-Step4ReadOnly`（命中即 `EXIT_CODE=4 violation_step4_write` + 自动回退，§8b 正确性不豁免）→ `step4/step4-review.md`，评级 `通过`/`需调整`。CLI 备用路径（mimo/codex）同理但 Save/Assert 均在 `run_step.ps1` 内自动完成。超时同样立即拆分，不得 `auto_pass_timeout` 静默转通过（已移除）。
7. **循环**：`需调整` → 回 Step 2（只处理未通过的 P + 新阻塞；入参加挂上轮复审）。Step 1 只做一次。上限默认 3 次（可配置到 10，见 shared/core-logic.md §6），超限汇报未解决问题。

## 硬性规则（主 agent）

- 每步等上一 subagent 返回后才进下一步；不可并行、不可跳步
- 主 agent 不得自己分析根因、写方案、改代码
- 传参只传原始问题/产物，禁止夹带倾向性结论
- Step 3 完成后必须立即进入 Step 4，不得中途停下汇报当"完成"
- 不得绕过 `run_step.ps1` 直接调用 `Task`、`harness-*` subagent 或 runner。`opencode-sub` 仅允许由 `bindings.step4.agent` 指定；任何其他 step 都必须在启动后端前 fail-closed，绝不返回 99。
- 合法 `step4/opencode-sub` 的 `EXIT_CODE=99` 仅是 Step 0 校验后的 orchestrator 移交信号。orchestrator 只能据此调度绑定角色，返回后继续既定 evidence 写入和只读快照断言，不能重新解释或替换 binding。
- 每次 CLI、超时、普通失败、拆分壁垒和合法 99 移交都必须留下同一 schema 的 `evidence.json`；99 的状态为 `handoff_pending`，不是 evidence 豁免。

## 违规处理

越权修改文件（含 step4 越权）：用 `baseline.diff`/备份精确回退（step4 经 `opencode/scripts/step4_readonly_guard.ps1` 快照比对自动回退，§8b）→ 从违规点重走 → **强制记录**到 `docs/violations.log`（`manage_binding.ps1 -RecordViolation`，禁止仅口头说明）。**正确性不豁免（§8b）**：即使越权改动技术正确且测试通过（例 107 passed）仍先回退，正确修复须经 `需调整 → 回 step2 修 F-<P> → step3 重执行` 链落地；两类反模式 F-P02（阈值过滤直接丢弃→应 deferred 回退）与 F-P07（优先本地号→应 len(product_rows)+1 保唯一）禁止 step4 私自落地。

更多细节（推荐矩阵、编号、循环、终止条件）见仓库 `shared/core-logic.md` 与 `shared/binding-recommendation.md`。

## 版本历史（Version History）

### v13.0.26 (2026-08-21)
- **F-P-01 ~ F-P-04**：强制四步唯一经 `run_step.ps1` 启动；`opencode-sub` 仅可作为已验证 step4 binding 的 99 移交；Step 0 对损坏 JSON 明确 fail-closed；修复实际 runner 调用，并统一 runner/orchestrator 的 evidence schema。

### v13.0.25 (2026-08-20)

- **Step4 越权自修复（§8b + 快照强制）**：针对 2026-08-20 两次 step4 越权（① `_select_diverse_actions` 把 `>0.72` 直接丢弃误杀 0.75 自拍、② `_upsert_generated_set_record` 把 `len(product_rows)+1` 改为优先本地号引入重号风险），新增 `shared/core-logic.md §8b` "正确性不豁免"原则（即使 107 passed 仍先回退、再经 需调整→step2 修方案→step3 重执行链落地），明确 F-P02 deferred 回退与 F-P07 不信任本地号两类反模式禁止 step4 私自落地；`opencode/scripts/run_step.ps1` 集成 `step4_readonly_guard.ps1` Save@step4前 / Assert@step4后（CLI 自动、opencode-sub 由 `harness-orchestrator` Task 后 Assert，命中即 `EXIT_CODE=4 violation_step4_write` + 自动回退），`harness-verifier.md` 与 `harness-orchestrator.md` 同步禁止"改对了就保留"的豁免企图并纳入违规记录强制点。

### v13.0.24 (2026-08-20)
- **V10/V11 自修复（用四步法修四步法）**：`bash --timeout 300000 + Tee-Object` 实时透传 `EXIT_CODE/ELAPSED/RAW`（F-P06/F-P07/F-P08/F-P09/F-P10/F-P15），移除 `run_step.ps1:152 auto_pass_timeout` 静默转通过（F-P01），补齐 `prechunk` 壁垒（F-P04）、递归深度感知（F-P11）、`shared/core-logic.md §6.1` 最小粒度注释（F-P05）、`dsh/scripts/run_step.ps1` 拆分闭环（F-P02），文档改“立即拆分不停下”（F-P03/F-P13/F-P14）。
- **binding 切换**：step1/2 因 claude 超时无法完成审计，临时切 `opencode-sub`（用户授权，见 `opencode/binding-lock.json authorization_log`），step3 仍 claude、step4 opencode-sub 保持 `step4≠step3` 约束。

### v13.0.23 (2026-08-19)
- **违规7 修复（step4 改用 opencode-sub）**：step4 绑定由 mimo CLI 改为 `harness-verifier` subagent（opencode-sub），用户显式授权记录于 binding-lock.json authorization_log；run_step.ps1 增加 opencode-sub 分派（EXIT_CODE=99）。
- **mimo runner 根因修复（F-MIMO-ROOTFIX）**：直接启动 node.exe + bin/mimo，绕过 .ps1 shim 与 powershell.exe 层，消除三层管道死锁与 -InputFormat XML 对 stdin 语义的破坏；stdin 改 UTF-8 字节直写（PS 5.1 无 StandardInputEncoding）。
- **violations.log 流程落实**：违规7 用 manage_binding.ps1 -RecordViolation 记录到仓库 docs/violations.log。

### v13.0.22 (2026-08-19)
- **三平台版本对齐**：v13.0.13 → v13.0.22，与 Hermes/dsh 对齐；发布前跑 `check_version_consistency.py` 强制三平台版本一致。
- **绑定表对齐 binding-lock.json**：step1/2/3=claude、step4=mimo 与机器可校验锁文件一致，消除 SKILL.md 声明漂移。
- **mimo hang 修复同步**：run_mimo_step3/4.ps1 改用 async drain（ProcessStartInfo + Output/ErrorDataReceived + UTF-8 + stdin 喂 prompt），消除管道死锁。
