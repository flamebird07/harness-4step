---
name: four-step-harness
description: "四步法 Harness + Loops 循环机制：审查→方案→执行→复审→循环直到通过。用独立 subagent 保证每步思维互不干扰、跳出逻辑死角；裁判不能当运动员。单一项目兼容 Hermes/opencode，共享逻辑见仓库 shared/。最小集 v13.0.13 引入脚本 orchestrator（run_step.ps1） + binding-lock.json fail-closed 校验 + 5 runner evidence.json 写盘 + BLOCKED_SPLIT_LIMIT 壁垒 + Pitfalls 节。Use when the user asks to run 四步法/4step/four-step harness/审查出方案执行复审/code review loop, or wants a bug fixed through separated audit-plan-implement-verify roles."
version: 13.0.43
---

# 四步法 Harness（opencode 适配层）v13.0.43 — r4 CLI 障碍修复

**逻辑源 = 仓库 `shared/core-logic.md`。** 本文件只做 opencode 落地：把共享逻辑映射到 opencode 的 subagent 与工具，不复制逻辑实现。逻辑有缺陷去改 shared/，本层只跟着更新引用。

**核心原则：裁判不能当运动员。** 每步独立互不干扰，不同 agent 以独立思维挑出彼此的逻辑死角。

## 与 Hermes 版的关系（单一项目）

| 维度 | Hermes 适配层 | opencode 适配层（本文件） |
|------|--------------|---------------------------|
| 执行后端 | `run_cli.py` + `binding-lock.json`（每步绑外部 CLI） | `scripts/run_step.ps1` 按 binding 路由 CLI，或以 99 移交对应 OpenCode 原生 subagent |
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
    "step4": { "agent": "codex", "model": null, "permission_mode": "default" }
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
| 1 | 审查 | **Claude Code CLI** | default | 只找问题，不写方案（P 编号） |
| 2 | 方案 | **Claude Code CLI** | default | 只写计划（F-<P编号> + before/after） |
| 3 | 执行 | **Claude Code CLI** | bypassPermissions | 严格按方案改，不分析 |
| 4 | 复审 | **Codex CLI** | read-only sandbox | 独立只读验证（读实际代码 + 必要的非写入式检查） |

- 每步均由 `run_step.ps1` 从本机锁读取当前绑定；本锁当前 Step 1–3=Claude、Step 4=Codex。若未来显式绑定为 `opencode-sub`，脚本以 `EXIT_CODE=99` 交由 OpenCode 的对应原生 `task` 子代理处理，不能自动换 CLI。

## codex CLI 调用规范（step4 备用路径，仅 mimo 认证失效且用户授权时使用）

```powershell
# 把复审 prompt 写入 .harness/<task>/step4-prompt.txt 后执行（V10 强制：bash 120s 截断 → 必须 timeout=300000 + Tee-Object 透传）：
bash --timeout 300000 -c "powershell.exe -NoProfile -File opencode/scripts/run_codex_step4.ps1 -PromptFile '.harness/<task>/step4-prompt.txt' -WorkspaceDir '<仓库根>' -OutDir '.harness/<task>/step4' | Tee-Object -FilePath '.harness/<task>/step4/run.log'"
# 产物：step4/codex_raw.jsonl（原始输出）、step4/step4-review.md（提取的 agent_message + 环境信息）
# 路径说明：仓库内用 opencode/ 相对路径；按 opencode/README.md 安装后脚本位于 <skill 目录>/scripts/，
# 调用对应改为 bash --timeout 300000 -c "powershell.exe -File \"<skill 目录>/scripts/run_codex_step4.ps1\" -PromptFile ... | Tee-Object ..."
```

- **连接前提**：脚本按 PATH 解析 `codex`；PATH 无 codex 时回退 `CODEX_HOME\.sandbox-bin\codex.exe`（`CODEX_HOME` 默认 `~/.ccsc/codex-mimo`，可用环境变量覆盖）。若认证失效会 401，需用户 `codex login`（或在 Codex 应用重新登录）。
- **只读强制（不可违反）**：`run_codex_step4.ps1` 用 `--sandbox read-only` 启动 codex，**blocked 一切写操作**（apply_patch / Edit / Write / 写文件命令）。step4 是复审者，只能读验证，绝不允许改文件。若 codex 尝试写文件会被 sandbox 拒绝并报错——这是预期行为，不是故障。
- prompt 必须包含：step1 原始问题清单（P 编号）+ 修改后文件绝对路径 + 明确要求"打开实际文件核对、能跑回归就跑、逐条评级、输出总体 通过/需调整"。
- 传给 codex 的 prompt 只含事实（问题 + 文件路径），不含主 agent 的倾向性结论。
- 若输出含 `NO agent_message` 或 `EXIT_CODE=-1`，重试一次；仍失败则记录后向用户汇报。

## mimo CLI 调用规范（step3 执行，当前绑定）

```powershell
# 把执行 prompt 写入 .harness/<task>/step3-prompt.txt 后执行（V10 强制：bash 120s 截断 → 必须 timeout=300000 + Tee-Object 透传）：
bash --timeout 300000 -c "powershell.exe -NoProfile -File opencode/scripts/run_mimo_step3.ps1 -PromptFile '.harness/<task>/step3-prompt.txt' -WorkspaceDir '<仓库根>' -OutDir '.harness/<task>/step3' | Tee-Object -FilePath '.harness/<task>/step3/run.log'"
# 产物：step3/mimo_step3_raw.txt（原始输出）、step3/step3-output.md
# 路径说明：仓库内用 opencode/ 相对路径；按 opencode/README.md 安装后脚本位于 <skill 目录>/scripts/，
# 调用对应改为 bash --timeout 300000 -c "powershell.exe -File \"<skill 目录>/scripts/run_mimo_step3.ps1\" -PromptFile ... | Tee-Object ..."
```

- **长 prompt 兼容性（关键）**：脚本用 **stdin 管道** 把 prompt 喂给 mimo，而非 argv 位置参数。Windows 上长 prompt 会破坏 mimo 的 argv 解析（与 kimi 相同），短 prompt 正常、长 prompt 报错即此问题。**不要改成 `--file`**：mimo 的 `-f/--file` 是贪婪的附件文件路径数组，会吞掉后续参数并报 `File not found`，不能用来传 prompt。
- 模型默认 `xiaomi/mimo-v2.5-pro`。
- 执行身份：`--dangerously-skip-permissions` 允许改文件（step3 职责）。

## mimo CLI 调用规范（step4 备用）

```powershell
# V10 强制：bash 120s 截断 → 必须 timeout=300000 + Tee-Object 透传
bash --timeout 300000 -c "powershell.exe -NoProfile -File opencode/scripts/run_mimo_step4.ps1 -PromptFile '.harness/<task>/step4-prompt.txt' -WorkspaceDir '<仓库根>' -OutDir '.harness/<task>/step4' | Tee-Object -FilePath '.harness/<task>/step4/run.log'"
# 产物：step4/mimo_raw.txt（原始输出）、step4/step4-review.md
# 路径说明：仓库内用 opencode/ 相对路径；按 opencode/README.md 安装后脚本位于 <skill 目录>/scripts/，
# 调用对应改为 bash --timeout 300000 -c "powershell.exe -File \"<skill 目录>/scripts/run_mimo_step4.ps1\" -PromptFile ... | Tee-Object ..."
```

- 仅当 codex 认证失效且用户显式授权切 mimo 时使用。模型默认 `xiaomi/mimo-v2.5-pro`。

## V10 强制调用约定（bash 120s 截断 → 300000+Tee-Object 透传）

> **根因**：opencode bash 工具默认 `timeout=120000` 且输出超 2000 行/51200 字节截断；各 runner 末尾才集中 `Write-Output EXIT_CODE/ELAPSED/RAW/OUTPUT`，120s 前无增量落盘，导致超时 `-2` 与耗时证据被吞没，拆分链无法触发。

> **P-07 外层 timeout 预算（v13.0.38）**：`run_step.ps1` 调用的外层 bash timeout 须 ≥ `MaxSplitDepth × TimeoutSeconds × 5`（覆盖递归 a/b 二分 + prechunk 串行），默认 180×3×5=2700s。原 300000ms(300s) 远不够（拆分链最坏 720-2700s），统一改为 **1800000ms（30min）**。`run_step.ps1` 内部另有 `MaxTotalBudget=1500s` 总预算守卫，超限即壁死+handoff 写 evidence，避免被外层硬杀留无证据。`manage_binding.ps1 -Check` / `run_vision_review.ps1` 等快速校验/单次调用保留 300000ms。
> **[F-06] quota 排队等待时长**：凭证池 429/quota 命中时 `run_step.ps1` 排队等待最长约 **30min**（10 次 × 每次 60-180s backoff），该期间豁免 `MaxTotalBudget` 总预算（等待≠任务工作）。故外层 bash timeout 调 `run_step.ps1` **不得 < 1800000ms**；等待耗尽仍失败输出 `INFRA_FAILURE_CRED_POOL_EXHAUSTED=1` + `EXIT_CODE=13`，由编排层 STOP 报告。
> **[F-05] timeout 生效来源优先级**：显式 `-TimeoutSeconds` 参数 > harness-config.json（`steps.<step>.timeout_seconds` 或 `defaults.timeout_seconds`）> 默认 180s。`run_step.ps1` 启动时若命中 config 会输出 `TIMEOUT_FROM_CONFIG=<step>=<s>`，与 `manage_binding.ps1 -ShowBindings/-Check` 展示值一致。

**强制**：所有 `bash` 调 `run_step.ps1 / manage_binding.ps1 / run_claude_step12.ps1 / run_mimo_step*.ps1 / run_codex_step4.ps1 / run_vision_review.ps1` 必须：

```powershell
# PowerShell 侧用 Tee-Object 实时落盘，bash 侧用 timeout=300000
bash --timeout 1800000 -c "powershell.exe -NoProfile -File opencode/scripts/run_step.ps1 -Step step1 -PromptFile '.harness/<task>/step1-prompt.txt' -WorkspaceDir '<仓库根>' -OutDir '.harness/<task>/step1' | Tee-Object -FilePath '.harness/<task>/step1/run.log'"
# manage_binding 校验同理：
bash --timeout 300000 -c "powershell.exe -NoProfile -File opencode/scripts/manage_binding.ps1 -Check | Tee-Object -FilePath '.harness/<task>/binding-check.log'"
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

### Pitfall 4 · v13.0.37 ArgumentList 方案在 PS 5.1 废棄（v13.0.38）
- **现象**：曾尝试用 `ProcessStartInfo.ArgumentList.Add(...)` 传 claude 参数（installed 副本一度标 v13.0.37 + 此 changelog）。`ArgumentList` 是 .NET Core 2.1+ 属性；PS 5.1（.NET Framework 4.x）无此属性 → `$psi.ArgumentList` 为 `$null` → `.Add()` 抛「不能对 Null 值表达式调用方法」×6 → claude.exe 收空参数 → "Input must be provided either through stdin or as a prompt argument" → EXIT_CODE=1，step1-3 全绑 claude 时 harness 完全不可用。
- **规则**：claude runner（`run_claude_step12.ps1`）必须用 `$psi.Arguments = '...'` 字符串拼接 + stdin pipe 喂 prompt（当前 v13.0.36/v13.0.38 实现）；**禁止改回 `ArgumentList`**。PS 5.1 也无 `StandardInputEncoding` setter（见 runner 注释，redirected StreamWriter 已默认 UTF-8，勿赋值）。
- **触发**：有人按旧 changelog 重新实现 ArgumentList 方案时。

### Pitfall 5 · bash 工具内联 PowerShell 的 `$_`/`$var` 被吞（external，v13.0.38）
- **现象**：opencode bash 工具把内联 `powershell.exe -Command "... $_.Name ..."` 中的 `$_`/`$var` 先做 bash 变量展开，`$_` 被替换为 `/usr/bin/bash`（bash 自身路径），PS 收到语法错误命令（如 `/usr/bin/bash.FullName`），本 session 已复现 3+ 次。
- **规则**：任何含 `$_` / `$PSVersionTable` / `$var` 的内联 PS 诊断**必须先写 .ps1 文件**再 `powershell.exe -NoProfile -File <file>.ps1` 执行；禁止 `powershell.exe -Command "..."` 内联带 PS 自动变量。本节所有示例均用 `-File` 调用脚本，不触发此坑。
- **触发**：在 bash 工具内联 `Get-ChildItem | ForEach-Object { $_.Name }` 等含 PS 自动变量的命令时。
- **推荐**：PS 诊断一律写 `.ps1` 临时文件（放 `.harness/<task>/tmp/` 或 `C:\Users\ADMINI~1\AppData\Local\Temp\opencode`），用 `powershell.exe -NoProfile -File` 执行，既绕开 `$_` 吞噬又留可复现脚本。

执行前可调用 `.harness/p20-prechunk-fix/scripts/preflight.ps1 -CommandText <text>`；它不执行命令，若发现 PowerShell `-Command` 与 `$_`、`$var` 或 `$PSVersionTable` 的组合则返回非零，打印精确原因及 `powershell.exe -NoProfile -File <file.ps1>` 建议。示例：拒绝 `powershell.exe -Command "Get-ChildItem | ForEach-Object { $_.Name }"` 和 `powershell.exe -Command "$PSVersionTable.PSVersion"`，通过 `powershell.exe -NoProfile -File check.ps1`。该轻量检查不覆盖混淆命令。

### Pitfall 6 · 修改后的 PowerShell 脚本必须保留 UTF-8 BOM（v13.0.40）
- **规则**：`run_step.ps1`、`run_claude_step12.ps1`、`run_mimo_step3.ps1` 和 `check-bom.ps1` 必须以 `EF BB BF` 开头。
- **检查**：`powershell.exe -NoProfile -File opencode/scripts/check-bom.ps1 -Files <paths>`；每个通过文件输出 `BOM_OK=<path>`，缺失输出 `BOM_MISSING=<path>` 并返回 1。
- **行为**：`run_step.ps1` 在加载 binding-lock 或选择 runner 前执行此 gate，任何缺失均 fail-closed 并列出路径；不会静默修复。

## 编排流程（唯一入口：`scripts/run_step.ps1`）

`step1` 至 `step4` 的唯一启动入口是 `scripts/run_step.ps1`。主 agent 不得直接调用 `Task`、任一 `harness-*` subagent 或任一独立 runner；必须先由该脚本完成 Step 0 的 lock/binding 校验，再按当前 `bindings.<step>` 路由。缺失、未锁定、非法或无法解析的 lock 一律 fail-closed，且不得启动 CLI 或 subagent。

1. **Step 0** 建工作区 `.harness/<task>/`，告知用户产物落盘位置。**V10 强制**：`bash --timeout 300000 -c "powershell.exe -File opencode/scripts/manage_binding.ps1 -Check | Tee-Object -FilePath .harness/<task>/binding-check.log"` 校验；`locked` 必须 `true`、step3 与 step4 模型族必须不同（`constraints.step4_must_differ_from_step3_family`）；任一不满足 orchestrator fail-closed 拒绝启动。绑定变更通过编辑 `binding-lock.json` 并在 `authorization_log` 追加条目实现。
2. **Step 1** `harness-auditor`：`bash --timeout 1800000 -c "powershell.exe -File opencode/scripts/run_step.ps1 -Step step1 ... | Tee-Object -FilePath .harness/<task>/step1/run.log"` → `step1-problems.md`（P 编号）。[F-04] claude default 已放行 Write/Edit 到 `.harness/<task>/**`，审查者把**完整**清单直接 Write 到 `<step1 OutDir>/step1-problems.md`；Write 被拒则全文输出由编排层落盘（不得只给摘要）。只读步骤超时 `EXIT_CODE=-2` → 立即走 `run_step.ps1:140 MaxSplitDepth=3` 拆分（`MaxAttempts=3`/`最小粒度<4行`/`EXIT_CODE=3 blocked_split_limit`），不得停下汇报。零问题则终止。
3. **Step 2** `harness-planner`：同上 `bash --timeout 1800000 … | Tee-Object` → `step2-plan.md`（F-<P编号>），[F-04] 同 step1 的 scoped Write/全文输出约束，超时同 V11 立即拆分。
4. **Step 2.5** 基线：git 仓库 `git diff > baseline.diff`；非 git 复制到 `backup/`。
5. **Step 3** 执行：把方案写入 `step3-prompt.txt` → `bash --timeout 1800000 -c "powershell.exe -File opencode/scripts/run_step.ps1 -Step step3 ... | Tee-Object -FilePath .harness/<task>/step3/run.log"` → 读 `step3/step3-output.md`。执行后对比基线验无方案外改动。
6. **Step 4** **`harness-verifier` subagent（opencode-sub）**：`bash --timeout 1800000 -c "powershell.exe -File opencode/scripts/run_step.ps1 -Step step4 ... | Tee-Object -FilePath .harness/<task>/step4/run.log"`（Save@step4前）→ Task 调 `harness-verifier` → 编排层 `Assert-Step4ReadOnly`（命中即 `EXIT_CODE=4 violation_step4_write` + 自动回退，§8b 正确性不豁免）→ `step4/step4-review.md`，评级 `通过`/`需调整`。CLI 备用路径（mimo/codex）同理但 Save/Assert 均在 `run_step.ps1` 内自动完成。超时同样立即拆分，不得 `auto_pass_timeout` 静默转通过（已移除）。
7. **循环**：`需调整` → 回 Step 2（只处理未通过的 P + 新阻塞；入参加挂上轮复审）。Step 1 只做一次。上限默认 3 次（可配置到 10，见 shared/core-logic.md §6），超限汇报未解决问题。

## 硬性规则（主 agent）

- **CLI 不可用时禁止自动降级（v13.0.42 硬不变规则，凌驾所有其他规则）**：任何 CLI/后端不可用场景（exit -1、exit 13、`API Error: Failed to parse JSON`、空输出、命令未找到、认证 401、沙箱拦子进程、`candidate not supported` 等）一律 **STOP 并向用户报告原始错误**，**不得自动改绑到另一个 backend**。orchestrator 必须等用户当轮明确授权（"降级到 X"或"用 X 继续"）才能调 `manage_binding.ps1 -AuthorizeStep/Steps`，并在 `authorization_log` 追加 `agent=X, authorization=<用户原话>`。**无用户原话 = 无授权 = 不降级**。即使 `binding-lock.json` 设了 `disable_auto_degrade=false`，orchestrator 仍须每轮重新获得用户授权。`-EmergencyInfraFailover` 即使代码级可用，也必须满足上述用户授权前提；否则按 `violations.log` 类别 `unauthorized_degrade` 记违规。此规则对应 `shared/core-logic.md §4（v13.0.42 硬不变规则段）`。**池耗尽信号（F-10）**：`run_step.ps1` 重试耗尽输出 `INFRA_FAILURE_CRED_POOL_EXHAUSTED=1` 时，编排层**不得静默重跑**，须 STOP 并向用户报告（凭证池已排队等待 N 次仍 429），等用户显式授权后再动作。
- **bash→PowerShell 唯一入口（F-01/F-02）**：bash 内调 PowerShell 一律 `scripts/ps.sh <ps1> [args…]`；**禁止**在 bash 内联 `powershell -Command "…$…"`（`$` 会被 bash 展开吞掉）。脚本路径与参数值**禁止反斜杠**（用 `C:/…` 或相对路径 `.harness/<task>/…`）；值含 `$`/`\` 先赋 shell 变量再传。`scripts/ps.sh` 对反斜杠/裸 `$` 参数 fail-closed（exit 2）。
- 每步等上一 subagent 返回后才进下一步；不可并行、不可跳步
- 主 agent 不得自己分析根因、写方案、改代码
- 传参只传原始问题/产物，禁止夹带倾向性结论
- Step 3 完成后必须立即进入 Step 4，不得中途停下汇报当"完成"
- 不得绕过 `run_step.ps1` 直接调用 `Task`、`harness-*` subagent 或 runner。`opencode-sub` 可由任一步的锁显式指定；脚本以 99 仅移交对应角色（step1→auditor、step2→planner、step3→implementer、step4→verifier），不得换用其他 CLI。
- 合法 `opencode-sub` 的 `EXIT_CODE=99` 是 Step 0 校验后的 orchestrator 移交信号。`task` 不可用、权限拒绝或子代理失败时，保留错误并报告；**不得将失败降级为 Hermes、其他 CLI 或主代理代做**（与上述 v13.0.42 硬规则一致：仍须用户当轮显式授权）。Step 4 返回后仍须执行既定 evidence 写入和只读快照断言。
- 每次 CLI、超时、普通失败、拆分壁垒和合法 99 移交都必须留下同一 schema 的 `evidence.json`；99 的状态为 `handoff_pending`，不是 evidence 豁免。
- 写工具（patch/write_file 等）被 gate 拦截时，禁止换用 python heredoc / `python -c` / `node -e` / shell 重定向直写、直调 `run_cli.py` 或 runner/subagent 等任何等价路径完成同一写入（shared/core-logic.md §8 类别 F）；唯一合法出口是走编排层流程或向用户报告。
- todo 同步纪律（强制，P-05）：每步经 run_step.ps1 分派前把对应 todo 项标为 `in_progress`；分派返回后立即更新——成功标 `completed` 并附产物路径 `.harness/<task>/step<N>/`，失败/拆分标 `blocked` 并附原因 + evidence 路径，`EXIT_CODE=99`（opencode-sub 移交）保持 `in_progress` 待子代理返回后收尾。断线重连先读 `.harness/<task>/task-state.json`（F-06）恢复各步状态，再据此重建 todo 面板。

## 违规处理

越权修改文件（含 step4 越权）：用 `baseline.diff`/备份精确回退（step4 经 `opencode/scripts/step4_readonly_guard.ps1` 快照比对自动回退，§8b）→ 从违规点重走 → **强制记录**到 `docs/violations.log`（`manage_binding.ps1 -RecordViolation`，禁止仅口头说明）。**正确性不豁免（§8b）**：即使越权改动技术正确且测试通过（例 107 passed）仍先回退，正确修复须经 `需调整 → 回 step2 修 F-<P> → step3 重执行` 链落地；两类反模式 F-P02（阈值过滤直接丢弃→应 deferred 回退）与 F-P07（优先本地号→应 len(product_rows)+1 保唯一）禁止 step4 私自落地。

更多细节（推荐矩阵、编号、循环、终止条件）见仓库 `shared/core-logic.md` 与 `shared/binding-recommendation.md`。

## 版本历史（Version History）

### v13.0.43 (2026-08-28)

- **r4 CLI 障碍修复**：新增 `scripts/ps.sh`（bash→PowerShell 唯一入口，禁内联 `-Command`/反斜杠归一/裸 `$` fail-closed，F-01/F-02）；claude step1/2 scoped `--allowedTools` 放行 `.harness/<task>/**` 产物（F-04）；`run_step.ps1` 读 `harness-config.json` timeout（F-05）；quota 排队等待内层重试环修复 P-06（10 次真实生效 + 预算豁免，F-06）；`INFRA_FAILURE_CRED_POOL_EXHAUSTED` 信号（F-10）；`core-logic.md §4b` 旧降级描述替换 + 重复标题修复（F-11）。详见 `SKILL.md` v13.0.43 条目。

### v13.0.42 (2026-08-27)

- **降级禁令硬不变规则固化**：CLI 不可用时一律 STOP + 报告原始错误，**不得自动改绑到另一个 backend**。orchestrator 必须等用户当轮明确授权才能降级；无用户原话 = 无授权 = 不降级。即使用户事先设了 `constraints.disable_auto_degrade=false`，orchestrator 仍须每轮重新获得用户授权。`-EmergencyInfraFailover` 即使代码级可用也必须满足用户授权前提，否则按 `violations.log` 类别 `unauthorized_degrade` 记违规。详见 `shared/core-logic.md §4 v13.0.42 段` + `opencode/agents/harness-orchestrator.md` 独立段 + `opencode/scripts/manage_binding.ps1` 文件头注释 + 本文件"硬性规则"首条。

### v13.0.41 (2026-08-27)

- **harness-self-fix-20260826r3（F-01R3 锁修复 + P-01..P-08 全部 F）**：并发锁根因修复——`manage_binding.ps1` 互斥句柄从数据文件改挂 sidecar `<lock>.mutex`（选项 C），数据文件永不持有 → `Move-Item` 覆盖不再被自身句柄阻塞（P-01/P-02 消除），新增 `Release-LockHandle` 幂等助手（F-01）；`-InstallFromRepo` 内联 Move 改为统一出口 `Write-LockAtomic`（F-02）；指纹比对随选项 C 复活（数据文件可重开），`-CleanupPendingFailovers` 循环内每轮刷新 `$fpNow` 防多条目假 fail-closed（F-03）；`-EmergencyInfraFailover` 补 `$fp0`+`Assert-LockWriteAvailable`+`Set-LastWriter`+catch 释放，`run_step.ps1` 调降级传 `-AcquireLock $taskId`（F-04）；todo 同步纪律强制（SKILL 硬性规则 + orchestrator 强制更新节 + todo 工具白名单 + 新增 `scripts/harness-status.ps1` 只读汇总）（F-05）；`run_step.ps1` 新增 `Write-TaskState`（PS 5.1 兼容）写 `.harness/<task>/task-state.json` + 5 出口调用（F-06）；prechunk 阈值放宽 `$prechunkLines=80`/`$prechunkTrigger=120`/`$chunkCharCap=15000`（F-07）；`harness-implementer.md` 新增「三态执行规则（强制，每轮重述）」独立段（F-08）。版本 13.0.40 → 13.0.41。

### v13.0.40 (2026-08-25)

- **p20-prechunk-fix（backlog 修复）**：`run_step.ps1:313` prechunk 触发条件去掉 opencode-sub 例外——所有绑定统一 prechunk（F-P20）；prechunk 循环聚合全部 99 handoff 为单条 `BINDING=opencode-sub STEP=<Step> SUBAGENT=<agent> CHUNKS=<n> EXIT_CODE=99`，不再在首个 99 处丢弃 chunks 2..N；`run_claude_step12.ps1` 新增 arg summary/prompt UTF-8 字节数/checked stdin write/完整 stderr 留存，检测 `API Error: Failed to parse JSON` → 发 `INFRA_FAILURE:other` + `INFRA_FAILURE_DETAIL:claude_json_parse` + exit 13（F-P18）；新增 `.harness/<task>/scripts/preflight.ps1` helper 拒绝 bash 内联 `powershell -Command` 携带 `$_`/`$var`/`$PSVersionTable`，Pitfall 5 补具体拒/通示例（F-P19）；`run_mimo_step3.ps1` 检测精确 `Text repetition detected` 签名 → 发 `INFRA_FAILURE:text_repetition` + exit 13 + evidence=infrastructure_error（F-P16）；新增 `check-bom.ps1`（[System.IO.File]::ReadAllBytes 验 EF BB BF）+ `run_step.ps1` Step 0 fail-closed BOM gate + Pitfall 6（F-P17）。

### v13.0.39 (2026-08-25)

- **p10-infra-failover（H-7 infra-failover 代码级）**：`manage_binding.ps1` 新增 `-EmergencyInfraFailover`（应急降级到 opencode-sub，TargetAgent 硬编码）+ `-CleanupPendingFailovers`（session 结束 ratify/回退）+ `-Check` stale pending 检测（>24h 自动回退+警告）；pending 状态存独立 `pending-auth.json`（不动 binding-lock schema_version，保持 v2）；`-FailureCategory` 枚举（runner_crash/pipe_deadlock/text_repetition/process_leak/other，拒绝 timeout/auth_failure/model_quality）；violations.log 新增结构化 infra-failure 条目（类别/降级目标/原始绑定/故障分类/pending授权路径）；`-EmergencyInfraFailover` 调 `Test-Step4FamilyDifferent` 前置校验，同族即 fail-closed 拒绝（不自动改 step4）；3 文件原子写（binding-lock+pending-auth+violations，tmp+Move，任一失败回滚，binding 最后写）；`run_step.ps1 Invoke-TaskWithSplit` 在 error-return 前检测 `EXIT_CODE=13`/stdout `INFRA_FAILURE:<category>` 信号触发降级+重试（reset attempt）；`shared/core-logic.md §4b` 第4项「代码 deferred」替换为实际 flag 引用。版本 13.0.38 → 13.0.39。

### v13.0.38 (2026-08-25)

- **harness-self-fix-20260825**：prechunk 跳过 opencode-sub 绑定 + 移除分片数 MaxSplitDepth 封顶（F-P01/P02）；claude runner ANTHROPIC_* 条件化保留指向 127.0.0.1 的本地代理凭据、strip dead endpoint（F-P04）；blocked_split_limit 后发 `SPLIT_BLOCKED_HANDOFF` 信号供编排层语义重拆（F-P06/P08）；外层 bash timeout 1800000ms + `run_step.ps1` 内 `MaxTotalBudget=1500s` 总预算守卫（F-P07）；runner 启动即写 `status=running` evidence（F-P09）；文档 `pwsh`→`powershell.exe`（PS 5.1）（F-P05）；新增 Pitfall 4（ArgumentList 废棄）+ Pitfall 5（bash `$_` 陷阱）（F-P03/P12）。installed 副本经重新安装从 repo 同步，消除 v13.0.37/ArgumentList/300s 漂移（F-P11/P14）。版本 13.0.36 → 13.0.38。

### v13.0.36 (2026-08-24)

- Claude CLI 改为直接启动 `claude.exe`，不再经 `Start-Job + stdin 管道`；发生超时时终止其完整子进程树，避免遗留进程导致后续步骤持续超时。
- 预拆分同时检查 UTF-8 字符数（6,000）和行数，短行数的大提示词不再绕过拆分。

### v13.0.35 (2026-08-24)
- 强制四步编排经 `run_step.ps1` 与 300 秒外层时限，保证 Claude `EXIT_CODE=-2` 可进入内建拆分；同步锁快照与角色表为当前 Step 1–3=Claude、Step 4=Codex。

### v13.0.34 (2026-08-24)
- 与 Hermes / DSH 同步版本：Codex Step 4 在 Windows 上动态解析当前 Desktop 沙箱助手，保持只读复审约束。

### v13.0.33 (2026-08-24)
- `binding-lock.json` 与 `manage_binding.ps1` 升级至 schema v2：后端模型族在 `backends` 中声明，Step 3/4 异族约束从配置校验；不再在管理脚本写死模型族映射。

### v13.0.32 (2026-08-24)

- **队列完整性对齐**：共享队列修复工具只恢复可验证的状态写回，不影响 OpenCode 的绑定策略或原生子代理分派。

### v13.0.31 (2026-08-24)

- **绑定契约对齐**：Hermes 后端绑定改为配置声明与通用校验；OpenCode 保持由自身 binding-lock 决定每一步的 CLI 或原生 subagent，不固化步骤后端。

### v13.0.30 (2026-08-24)

- **原生子代理对称性**：`opencode-sub` 现可绑定至 Step 1–4，并经唯一入口发出 `STEP`/`SUBAGENT` 移交信号；不再把前三步强制转为外部 CLI，也不允许 CLI 故障自动跨运行时降级。

### v13.0.27 (2026-08-23)

- **两轮自修复补全（绑定防护 + 基础设施五缺陷修复 + §8-F）**：第一轮补强绑定防护，明确禁止将模型或 CLI 语境描述误解为改绑指令；第二轮修复基础设施缺陷，包括 Codex 完整 bundle 的版本哈希子目录识别、拆分子分片返回后的 step4 只读断言及相关 runner 一致性问题；共享规则新增 §8 类别 F，禁止 gate-bypass writing。三平台版本号 13.0.26 → 13.0.27。

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
