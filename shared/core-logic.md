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
| Step 3 | 执行者 | 严格按方案逐条修改 | 不分析根因、不扩大范围、不重构 |
| Step 4 | 复审者 | 打开实际代码核对 + 只读核对命令，输出评级 | 不自己修复 |

**Step 4 评级**: `通过` / `需调整`。`需调整` → 回到 Step 2（不回 Step 1；Step 1 只做一次）。

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

| 能力 | Hermes 适配层 | opencode 适配层 | DeepSeek Harness (DSH) 适配层 |
|------|--------------|-----------------|------------------------------|
| 执行后端 | `run_cli.py` + `binding-lock.json` | bash 调 CLI（绑定由 `binding-lock.json` + `manage_binding.ps1` 管理）+ `task` 调度 subagent（备用） | DSH `subagent` 工具为主（`dsh-sub`，经 `run_step.ps1` 输出信号后由主 agent 调度）+ 可选 CLI（复用 opencode runner，经 pwsh） |
| 配置 | `~/.hermes/binding-lock.json` + `harness-config.yaml` | `opencode/binding-lock.json`（模板）+ `harness-config` + `opencode/SKILL.md` | `~/.dsh/harness/binding-lock.json`（模板 `dsh/binding-lock.json`）+ `harness-config` + `dsh/SKILL.md` |
| 反绕过 | `plugin/`（four-step-enforcer 插件） | 绑定 CLI：prompt 只读前缀 + 统一经 `scripts/` 脚本调用 + 事后基线回退；绑定 opencode-sub：subagent `permission: edit: deny` | 绑定 dsh-sub：提示词强制只读（DSH 无权限字段）+ 统一经 `run_step.ps1` 分派 + 事后 `git diff > baseline.diff` 回退 |
| 模型族 | CLI 侧配置 | CLI 侧配置 / opencode-sub 固定族 | `dsh/binding-lock.json` 的 `models` 字段决定 dsh-sub 的族；step4≠step3 必须不同族（`manage_binding.ps1 -Check` 强制） |

任何平台**不得在本文件之外**复制逻辑实现；适配层只实现调用，不重新发明逻辑。