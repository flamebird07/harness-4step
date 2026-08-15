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

### 3b. 引用规范（防行号漂移）
跨文档引用规则一律用「章节锚点」而非行号，例如 `SKILL.md#binding-mechanism`、`SKILL.md#enforcement-gates`、`SKILL.md#declared-fallback`。行号仅作为当前版本的辅助定位，不作为长期引用依据；文档增删后不得声称行号仍有效。

## 4. 绑定语义（步骤 → 后端）

每个步骤绑定一个"后端"。后端分两类：

- **CLI 后端**：外部 agent CLI（codex / claude / kimi / mimo 等），通过 shell 调用真实二进制
- **Subagent 后端**：宿主平台内的独立子 agent（opencode 的 `harness-*`；Hermes 的 plugin/delegate 受控）

同一 CLI 可绑定不同步骤；**Step 4 必须与执行步骤（Step 3）使用不同模型族**，避免复审盲区。

绑定变更必须是**用户显式授权**，禁止执行者/审查者自行改绑定来绕过失败。

## 4b. 只读步骤（step1/2/4）失败处置优先级

同一只读步骤失败/超时时，处置顺序固定为：

1. 一次精简重试（仅当失败类型可重试，见 Hermes 适配层 Failure Classification Matrix）
2. **拆分**（拆分优先于降级）：触发拆分门（**首次超时**或**两次非超时失败**）→ 生成子项，各子项独立走完整 4 步
3. 降级换 CLI **仅限**：拆分已达最小粒度壁垒（单一函数/行区间，`BLOCKED_SPLIT_LIMIT`）仍失败，或该步绑定后端不可用（command not found / 认证 401）且无可拆分单元。

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
**处置（任一类别命中）**：
1. 用 `baseline.diff`/备份精确回退（step4 越权写文件：适配层 F-08 已自动从快照回退）
2. 从违规点起重走流程
3. **强制记录**：调 `manage_binding.ps1 -RecordViolation`（opencode 适配层）/ `run_cli.py` 对应记录（Hermes 适配层）追加到 `violations.log`（原因 + 责任人 + 时间戳）；记录是强制动作，禁止仅口头说明或跳过（触发点清单见 opencode/harness-orchestrator#违规记录强制点）

## 9. 终止条件

任一满足即终止：
- Step 4 评级 `通过`
- 循环达上限
- Step 1 零问题 → 报告"无需修复"

## 10. 平台适配层职责

| 能力 | Hermes 适配层 | opencode 适配层 | DeepSeek Harness (DSH) 适配层 |
|------|--------------|-----------------|------------------------------|
| 执行后端 | `run_cli.py` + `binding-lock.json` | bash 调 CLI（绑定由 `binding-lock.json` + `manage_binding.ps1` 管理）+ `task` 调度 subagent（备用） | DSH `subagent` 工具为主（`dsh-sub`，经 `run_step.ps1` 输出信号后由主 agent 调度）+ 可选 CLI（复用 opencode runner，经 pwsh） |
| 配置 | `~/.hermes/binding-lock.json` + `harness-config.yaml` | `opencode/binding-lock.json`（模板）+ `harness-config` + `opencode/SKILL.md` | `~/.dsh/harness/binding-lock.json`（模板 `dsh/binding-lock.json`）+ `harness-config` + `dsh/SKILL.md` |
| 反绕过 | `plugin/`（four-step-enforcer 插件） | 绑定 CLI：prompt 只读前缀 + 统一经 `scripts/` 脚本调用 + 事后基线回退；绑定 opencode-sub：subagent `permission: edit: deny` | 绑定 dsh-sub：提示词强制只读（DSH 无权限字段）+ 统一经 `run_step.ps1` 分派 + 事后 `git diff > baseline.diff` 回退 |
| 模型族 | CLI 侧配置 | CLI 侧配置 / opencode-sub 固定族 | `dsh/binding-lock.json` 的 `models` 字段决定 dsh-sub 的族；step4≠step3 必须不同族（`manage_binding.ps1 -Check` 强制） |

任何平台**不得在本文件之外**复制逻辑实现；适配层只实现调用，不重新发明逻辑。