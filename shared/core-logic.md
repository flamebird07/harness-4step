# Harness 4-Step Method — 共享核心逻辑（平台无关）

> 本文件是四步法**唯一逻辑源**。Hermes、opencode 与 DeepSeek Harness (DSH) 三个平台都引用本文件，任何逻辑优化只在这里改一次，各平台同步生效。
> 平台差异（CLI 调用方式、subagent 权限、队列、超时处理等）不写在这里，写在各平台的适配层。

## 1. 核心原则

**裁判不能当运动员。** 审查的人不能同时写代码；写代码的人不能决定改什么。每步必须**独立、互不干扰**，由不同 agent 以独立思维挑出彼此的逻辑死角。分权制衡才能发现问题。

## 2. 四步（严格顺序，不可跳步、不可并行）

| 步骤 | 角色 | 职责 | 硬性边界 |
|------|------|------|----------|
| Step 1 | 审查者 | 只找问题，输出问题清单（带编号） | 不写方案、不改代码 |
| Step 2 | 方案者 | 基于问题清单出修复方案（before/after） | 不改代码、不出无编号改动 |
| Step 3 | 执行者 | 严格按方案逐条修改 + 必须验证（语法/回归，能跑就跑，如实报告） | 不分析根因、不扩大范围、不重构；不得仅凭人工目检自评通过；验证被权限/环境拦截时须如实记录"未验证"并传 Step 4（见 §2b） |
| Step 4 | 复审者 | 打开实际代码核对 + 只读核对命令（必要时兜底只读回归，§2c），输出评级 | 不自己修复；只读由适配层技术强制（快照比对/沙箱/edit:deny，§8），不只靠 prompt |

**Step 4 评级**: `通过` / `需调整`。`需调整` → 回到 Step 2（不回 Step 1；Step 1 只做一次）。

## 2b. Step 3 验证门（validation gate）
Step 3 判"完成"的必要条件是以下任一：
1. 自动化验证通过：产物 `Step 3 验证状态` 含已执行的语法/回归检查且全部 passed（附命令与证据）。
2. 显式未验证：自动化验证被权限/环境拦截（approval 提示、工具缺失、沙箱禁测）→ 必须记录
   `验证状态: blocked(<命令>/<原因>)` 或 `not-run(<原因>)`，写入 step3 产物并原样传给 Step 4。
仅"人工目检"（Read 目检）不构成验证，不得据此判 Step 3 完成。
验证命令裁决（P-05）：step3 允许尝试只读验证（`git diff --check`、只读语法检查等，见适配层 run_claude_step12.ps1 前缀）与环境允许时的回归；回归的最终兜底在 Step 4（§2c）。验证命令被拦截不算实现失败，不得据此判实现错误。
## 2c. Step 4 兜底验证（fallback validation）
Step 4 必须读取 Step 3 验证状态后决定是否补跑回归：
- step3 验证状态 = passed → Step 4 可抽查，不必重跑；
- step3 验证状态 = blocked / not-run → Step 4 必须尝试补跑只读回归（允许命令白名单见适配层）；仍被拦截则如实记录，**验证未完成的修复不得判"通过"**（整体状态不得为 COMPLETED，对齐顶层 SKILL.md#Terminal-Statuses）。
- step3 验证状态 = failed → Step 4 复跑确认细节，据此评级 `需调整`。

## 3. 问题与方案编号（追溯）

- 问题统一编号 `P-01, P-02…`
- 方案统一编号 `F-<P编号>`× 每个修复必须对应一个问题
- 全流程凭编号追溯，**禁止出现无编号内容**

### 3a. 方案分层（三态，v13.0.41 harness-self-fix-20260826 新增）

Step 2 方案的每个 F 项必须标注三态之一，Step 3 严格按态执行（防止实施者自行决定做不做）：

- `[必做]`：必须实施。Step 3 落地并完成验证门（§2b）。
- `[可选-建议实施]`：建议实施但非硬性。Step 3 可实施；若跳过须在产物注明原因，不得静默忽略。
- `[可选-不实施]`：**禁止实施**。Step 3 不得落地该 F 项；如认为必须实施，须先回 Step 2 将该项改标为 `[必做]` 或 `[可选-建议实施]`、完成新一轮方案评审（含 Step 4）后，再重新进入 Step 3。本轮擅自实施视为执行者越权（§8 B 类）。

### 3b. 引用规范（防行号漂移）
跨文档引用规则一律用「章节锚点」而非行号，例如 `SKILL.md#binding-mechanism`、`SKILL.md#enforcement-gates`、`SKILL.md#declared-fallback`。行号仅作为当前版本的辅助定位，不作为长期引用依据；文档增删后不得声称行号仍有效。

## 4. 绑定语义（步骤 → 后端）

每个步骤绑定一个"后端"。后端分两类：

- **CLI 后端**：外部 agent CLI（codex / claude / kimi / mimo 等），通过 shell 调用真实二进制
- **Subagent 后端**：宿主平台内的独立子 agent（opencode 的 `harness-*`；Hermes 的 plugin/delegate 受控）

同一 CLI 可绑定不同步骤；**Step 4 必须与执行步骤（Step 3）使用不同模型族**，避免复审盲区。

绑定变更必须是**用户显式授权**，禁止执行者/审查者自行改绑定来绕过失败。

**v13.0.42 硬不变规则（CLI 不可用时禁止自动降级）**：
- 任何 CLI/后端不可用场景（exit -1、exit 13、API Error、空输出、命令未找到、认证 401、沙箱拦子进程等）一律 **STOP 并向用户报告**，**不得自动改绑到另一个 backend**。
- 自动改绑是 orchestrator 自作主张的违规行为（v13.0.9#5 禁止的绕过场景），即使降级目标在 `CandidateAgents` 列表内、即使有 `disable_auto_degrade=false` 配置，**也不得**未经用户当轮显式回复授权就触发。
- 唯一例外：当用户**当轮问答**明确说"降级到 X"或"用 X 继续"时，orchestrator 才有权调 `manage_binding.ps1 -AuthorizeStep/Steps`，并在 `authorization_log` 追加一条 `agent=X, authorization=<用户原话>`。无用户原话 = 无授权 = 不降级。
- `-EmergencyInfraFailover`（H-7 文档降级）即使代码级可用，也必须满足上述用户授权前提才被 orchestrator 调用；否则视为违规（violations.log 类别=unauthorized_degrade）。
- 这条规则**凌驾** §4b 第 3/4 项的"降级换 CLI"和"基础设施故障应急降级"——即使用户事先在 `binding-lock.json` 设了 `disable_auto_degrade=false`，orchestrator 仍须每轮重新获得用户授权才能触发。

## 4b. 只读步骤（step1/2/4）失败处置优先级

## 4b. 只读步骤（step1/2/4）失败处置优先级

同一只读步骤失败/超时时，处置顺序固定为：

1. 一次精简重试（仅当失败类型可重试，见 Hermes 适配层 Failure Classification Matrix）
2. **拆分**（拆分优先于降级）：触发拆分门（**首次超时**或**两次非超时失败**）→ 生成子项，各子项独立走完整 4 步
3. 降级换 CLI **仅限**：拆分已达最小粒度壁垒（单一函数/行区间，`BLOCKED_SPLIT_LIMIT`）仍失败，或该步绑定后端不可用（command not found / 认证 401）且无可拆分单元。
4. **基础设施故障应急降级（v13.0.38 doc-only；v13.0.39 代码实现）**：当失败根因是**运行器自身代码 bug**（如 v13.0.37 ArgumentList 在 PS 5.1 崩溃、runner 进程泄漏、stdin 管道死锁），而非模型质量/超时/认证时，允许 orchestrator 临时把该步切到 `opencode-sub`/`dsh-sub`（原生子代理）并**立即记录 violations.log**（类别=infra-failure），随后在**同一 session 内补用户显式授权**（`manage_binding.ps1 -AuthorizeStep` 补写 authorization_log）；若 session 结束前未补授权，回退绑定并报告。此类别**不得**用于模型输出质量、超时、prompt 过大——这些仍走拆分/循环。代码级实现见 `opencode/scripts/manage_binding.ps1 -EmergencyInfraFailover` 标志 + retroactive-auth 流程（v13.0.39 落地）：`-EmergencyInfraFailover -Step <step> -FailureCategory <runner_crash|pipe_deadlock|text_repetition|process_leak|other> -FailureEvidence <证据> -Reason <文本>` 原子写 binding-lock.json（改 opencode-sub/dsh-sub）+ `pending-auth.json`（独立 pending 态，不动 binding-lock schema_version）+ `docs/violations.log`（结构化 infra-failure 条目）；session 内补 `-AuthorizeStep` ratify，未补则 `-CleanupPendingFailovers`（session 结束）或 `-Check`（stale>24h 自动回退）回退绑定。`run_step.ps1 Invoke-TaskWithSplit` 在 error-return 前检测 `EXIT_CODE=13` 或 stdout `INFRA_FAILURE:<category>` 信号触发降级+重试。fail-closed 绑定门保留（pending 授权未补即回退，不构成旁路）。

规则：只读步骤在任何情况下**不得**因为「问题过大/质量不佳」而换 CLI 降级——那正是 v13.0.9#5 禁止的绕过。拆分优先的理由：换 CLI 不降问题的固有复杂度，只换模型；且拆分不触碰绑定锁，不构成绑定违规。opencode 适配层只在本节落地相同的拆分信号（`run_step.ps1 -SplitOf`），不复制判定逻辑。

## 5. 按步骤特性推荐（详见 `shared/binding-recommendation.md`）

- Step 1 审查：深度读代码 → 推荐强分析模型（claude/codex；opencode 高智力模型）
- Step 2 方案：精确规划 → 强生成模型（claude/codex）
- Step 3 执行：精确改码、重成本 → 便宜快速模型（mimo）、或宿主内权限限定 subagent
- Step 4 复审：**与 Step 3 不同模型族** → codex / 或三选一错开

## 6. 循环机制

- 触发：Step 4 评级 `需调整` 或新阻塞问题
- 回退点：Step 2，**仅针对未通过的编号 + 新阻塞项**，禁止范围蔓延
- 上限：默认 3 次，可配置到 10，超限停止并向用户报告全部未解决问题

### 6b. 拆分与循环的关系
- **拆分**（split）与**循环**（loop）是两个独立、串接的机制，非二选一：
  1. 拆分在「只读步骤失败/超时」时触发：父 item 拆为若干子项，各子项独立走完整 step1→4。
  2. 循环在「单个 item 的 Step 4 评级需调整」时触发：该 item 回 Step 2 重做（不回 Step 1）。
  3. 串接：拆出的任一子项在完成自己的 step1→4 后，若其 Step 4 仍 `需调整`，则该子项进入自己的循环（回 Step 2）。拆分与循环逐级嵌套，互不短路。
- 心智模型：拆分是「横向降载」（把大问题切小），循环是「纵向迭代」（把同一子问题做对）。两者正交，可叠加。

## 7. 执行前基线（Step 3 前置）

- git 仓库：`git diff > baseline.diff`
- 非 git：复制相关文件到 `backup/`
- 目的：违规/出错时精确回退，不依赖盲目 `git revert HEAD`

## 8. 违规处理
**违规类别（任一命中即按本节处置）**：
- A. 越权写文件：审查者（step1/2/4）修改了任何目标文件（step4 触发见适配层 F-08 快照比对）
- B. 执行者越权：step3 超出方案范围/编号自定改动（不分析根因、不扩大范围、不重构）
- C. 跳步 / 并行：未按 step1→4 顺序或违规并行
- D. **验证被拦截（validation-blocked）**：step3 需要自动化验证（语法/回归），但命令被权限/环境拦截（approval 提示、工具缺失、沙箱禁测）——必须如实记录 `验证状态: blocked(<命令>/<原因>)` 或 `not-run(<原因>)` 并传给 step4；**不得**以"人工目检"自评通过（§2b 验证门）
- E. 复审者假通过：step4 在验证未完成/被拦截时仍判 `通过`
- F. **旁路写入（gate-bypass writing）**：主 agent 或任一步骤在 patch/write_file 等写工具被 gate 拦截后，换用任何等价手段直写文件——python heredoc / `python -c`、`node -e`、shell 重定向直写目标代码、直调 `run_cli.py` 改仓库文件、未经编排层派发直调 runner/subagent、以及非「编排层精确回退」用途的 `git checkout`/`git restore`。「换个工具做同一件被拦的事」与直接违规同罪：命中即停止当前动作，按本节处置 1)-3) 回退并记录。
**处置（任一类别命中）**：
1. 用 `baseline.diff`/备份精确回退（step4 越权写文件：适配层 F-08 已自动从快照回退）
2. 从违规点起重走流程
3. **强制记录**：调 `manage_binding.ps1 -RecordViolation`（opencode 适配层）/ `run_cli.py` 对应记录（Hermes 适配层）追加到 `violations.log`（原因 + 责任人 + 时间戳）；记录是强制动作，禁止仅口头说明或跳过（触发点清单见 opencode/harness-orchestrator#违规记录强制点）

### 8b. 越权修复的"正确性不豁免"原则（v13.0.25 新增 — 针对 2026-08-20 两次 step4 越权）

**原则**：step4 越权修改即使"改对了、且全量测试通过"仍属违规，**不得直接保留**，必须先回退再按正规循环重做。正确性不豁免流程正义。

- **保留 ≠ 豁免**：测试转绿（例 107 passed）只证明改动技术层面正确，不消除越权事实。保留论证必须经 `step4 评级需调整 → 回 step2 修方案 → step3 重执行` 的循环链重新落地；跳过循环的直接保留视为流程违规。
- **两类典型越权反模式（禁止 step4 私自落地）**：
  1. **过滤丢弃 → 延迟回退（F-P02 型）**：相似度/阈值过滤不得直接丢弃候选；正确形态是 `deferred 列表 + 数量不足回退补齐`。Step3 误杀候选导致的回归（如 0.75 相似度自拍被误杀、单测失败），step4 只能判 `需调整` 并在复审意见中写明"应改为 deferred 回退"，由 step2 修 F-P02 后 step3 重跑。
  2. **信任本地号 → 回退为表自增（F-P07 型）**：并发/丢弃批次场景下重号风险与既有设计"不信任本地 set_number"冲突时，step4 不得私自把 `优先本地 set_number` 回退为 `len(product_rows)+1`。正确路径是 step4 判 `需调整` 并指出"方案与 F-01 设计冲突、存在重号风险"，回 step2 修订/废止 F-P07 后 step3 重跑。
- **处置细化**：命中 A 类越权且改动事后被判定技术正确时，仍执行 §8 1) 回退快照 → 2) step4 产物改为 `评级: 需调整` 附带正确修复要点 → 3) 记录 violations.log 追加 `处置: 已回退，正确修复已纳入 F-<P> Rev.2 由 step3 重执行验证`。任何"保留越权改动"的捷径必须走用户显式授权的 binding/方案修订，不得由复审者单方面决定。

## 9. 终止条件

任一满足即终止：
- Step 4 评级 `通过`
- 循环达上限
- Step 1 零问题 → 报告"无需修复"

## 10. 平台适配层职责

| 能力 | Hermes 适配层 | opencode 适配层 | DeepSeek Harness (DSH) 适配层 |
|------|--------------|-----------------|------------------------------|
| 执行后端 | `run_cli.py` + `binding-lock.json` | bash 调 CLI（绑定由 `binding-lock.json` + `manage_binding.ps1` 管理）+ `task` 调度 subagent（备用） | DSH `subagent` 工具为主（`dsh-sub`，经 `run_step.ps1` 输出信号后由主 agent 调度）+ 可选 CLI（复用 opencode runner，经 powershell.exe） |
| 配置 | `~/.hermes/binding-lock.json` + `harness-config.yaml` | `opencode/binding-lock.json`（模板）+ `harness-config` + `opencode/SKILL.md` | `~/.dsh/harness/binding-lock.json`（模板 `dsh/binding-lock.json`）+ `harness-config` + `dsh/SKILL.md` |
| 反绕过 | `plugin/`（four-step-enforcer 插件） | 绑定 CLI：prompt 只读前缀 + 统一经 `scripts/` 脚本调用 + **step4 快照强制（Save/Assert，§8b）** + 事后基线回退；绑定 opencode-sub：subagent `permission: edit: deny` **+ 主编排层快照强制（Save@step4前 → Assert@step4后，§8b）** | 绑定 dsh-sub：提示词强制只读（DSH 无权限字段）+ 统一经 `run_step.ps1` 分派 + **step4 快照强制（Save/Assert，§8b）** + 事后 `git diff > baseline.diff` 回退 |
| 模型族 | CLI 侧配置 | CLI 侧配置 / opencode-sub 固定族 | `dsh/binding-lock.json` 的 `models` 字段决定 dsh-sub 的族；step4≠step3 必须不同族（`manage_binding.ps1 -Check` 强制） |
| 视觉审查 | **自带视觉识别，不触发**（§11） | 经共享 runner `opencode/scripts/run_vision_review.ps1`（mimo CLI + 视觉模型） | 同左（经 `../../opencode/scripts/run_vision_review.ps1`，复用共享 runner） |

任何平台**不得在本文件之外**复制逻辑实现；适配层只实现调用，不重新发明逻辑。

## 11. 视觉审查（四步法内部视觉兜底，不是新步骤）

**定位**：视觉审查是四步法流程内部的**跨步视觉兜底能力**，用于当四步法某一步**需要视觉判断**、而该步绑定的执行工具（subagent / CLI）**不具备视觉能力**时。它**不是第五步**，不改变 step1→4 的顺序与跳步约束；视觉结论作为对应步骤的**输入佐证**，该步仍由原绑定后端执行/输出。

**适用平台**：DeepSeek Harness（DSH subagent 默认无视觉）与 opencode（CLI/subagent 均无视觉）**必须支持**；Hermes **自带视觉识别，不触发本机制**。

### 11a. 触发条件（满足任一即触发）

某一步涉及视觉判断，且该步绑定后端无视觉：
- **Step 1 审查**：问题涉及 UI/页面/图片资源，审查者需看截图/渲染图找视觉问题
- **Step 3 执行**：实现完成后需确认视觉效果（如改了 CSS/布局，需看图核对是否符合方案）
- **Step 4 复审**：需对比 before/after 截图核对视觉效果是否符合预期

判定：主 agent 判断任务是否需要视觉判断；需要时先确认该步绑定后端是否具备视觉（DSH subagent / opencode CLI 均视为无视觉）→ 无视觉则触发视觉审查。

### 11b. 调用机制

1. 截图/渲染图**先落盘**（脚本/浏览器截图生成 png；主 agent 或执行者生成）。
2. 主 agent（或对应 subagent）经适配层视觉 runner 看图：
   - 共享 runner：`opencode/scripts/run_vision_review.ps1`（平台无关 PowerShell，mimo CLI + 视觉模型）
   - 调用：`-ImageFiles <图1>,<图2> -Prompt <审查重点> -WorkspaceDir <根> -OutDir <产物>`
   - 默认视觉模型 `xiaomi/mimo-v2.5`（可经 `-Model` 覆盖为 mimo-v2.5-pro 等）
   - 产物：`<OutDir>/vision-review.md`（mimo 视觉结论）+ 退出码（0 成功 / -2 超时 / -3 错误）
3. 视觉结论是**只读佐证**：绝不修改目标代码，只写 `.harness/<task>/vision/` 产物；视觉结论**不得虚构**——mimo 输出是唯一事实来源，图片打不开/CLI 失败/超时一律如实报告 `blocked(<原因>)`，不得编造"看到的内容"。

### 11c. 与各步骤的关系

| 触发步骤 | 视觉审查时机 | 结论用途 |
|----------|-------------|----------|
| Step 1 | 审查前先看图（截图需已落盘） | 视觉问题并入问题清单（P 编号） |
| Step 3 | 实现后看图核对 | 作为该步验证的一部分：视觉不符 → 如实记录，不回退但如实传 Step 4 |
| Step 4 | 复审时对比 before/after | 作为评级 `通过`/`需调整` 的视觉证据；视觉不符 → `需调整` |

**边界**：视觉审查不改变绑定、不构成新步骤、不绕过 Step 4 与 Step 3 不同模型族约束（视觉模型仅看图，不替代 step4 的复审后端）；视觉审查结果与 step3 验证状态（§2b/§2c）是**两条独立证据线**，都须如实记录与传递。

### 11d. 实现（各适配层）

- **共享 runner**：`opencode/scripts/run_vision_review.ps1`（mimo CLI + `-f` 附加多图，mimo 需 positional message 才会执行）
- **DSH**：`dsh/SKILL.md` + `dsh/agents/vision-reviewer.md`（subagent 模板，经 `../../opencode/scripts/run_vision_review.ps1` 调用）
- **opencode**：`opencode/SKILL.md` + `opencode/agents/harness-orchestrator.md`（路由规则）
- **Hermes**：不实现（自带视觉，§11 不适用）### 6.1 超时拆分壁垒（BLOCKED_SPLIT_LIMIT）
当某步 CLI 超时（`EXIT_CODE=-2`），适配层可把当前 prompt 拆成子项分别重跑，但必须受以下壁垒约束，防止无限拆分/递归爆炸：
- **最小拆分粒度 = 单文件（实现判定：prompt 行数 < 4 时视为已达最小粒度，不得再拆，对应 `opencode/scripts/run_step.ps1:171`）**：拆到以单文件为单位的子 prompt 后不得再拆；已是最小粒度仍超时即触壁垒（`status=blocked_split_limit`/`EXIT_CODE=3`）。
- **最大递归深度 = 3**（可配置 `MaxSplitDepth`）：子项再超时可继续拆，但深度达 3 即停。
- **最大尝试次数 = 3**（可配置 `MaxAttempts`）：超 `MaxAttempts` 或 `MaxSplitDepth` 任一即触壁垒。
- **降级出口**：触壁垒时写 `evidence.json` 字段 `status="blocked_split_limit"`、`exit_code=-2`，进程以 `EXIT_CODE=3` 返回，并向上游报告"该子问题无法在自动拆分内闭环，需人工介入或重切绑定"。
- **不绕过绑定**：拆分重跑沿用原步绑定，禁止借拆分换模型族（换绑定走 Step 2 显式授权）。
- **壁死后语义重拆 handoff（v13.0.38 新增，针对机械行二分不降负载）**：触壁垒（`status=blocked_split_limit`/`EXIT_CODE=3`）时，适配层除写 evidence 外须额外向 stdout 输出 `SPLIT_BLOCKED_HANDOFF=<原 prompt 文件>` + `NEEDS_SEMANTIC_RESPLIT=1` 信号；编排层（orchestrator）消费该信号后，把**原 prompt** 按问题维度（如按文件 / 按审计子目标）语义重拆为若干 focused 子 prompt，各子项作为新 item 入队独立走完整 step1→4。此为横向语义降载出口，与递归行二分（纵向）正交：行二分把大 prompt 切小但每半仍是同质任务（仍读同一大文件、工作量不减），语义重拆按维度切分让每子项工作量真正下降。语义重拆**不换绑定**（沿用原步 CLI/subagent）、**不豁免 §8b**（越权仍回退+循环）；仅最小粒度壁垒 + 语义重拆均失败后才走 §4b 显式授权降级。

_此节由 opencode 端 v13.0.13 miniset 升级引入（2026-08-18）。详见 `opencode/scripts/run_step.ps1` 与 `opencode/SKILL.md` 的 Pitfalls 节。_

