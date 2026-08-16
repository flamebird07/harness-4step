# DSH 适配层（Harness 4-Step Method — DeepSeek Harness）

单一项目 `flamebird07/harness-4step`，同时兼容 Hermes、opencode 与 DeepSeek Harness (DSH)。本目录是 DSH 侧实现。

## 架构

```
harness-4step/            # GitHub 仓库（同一仓库）
├── shared/               # 唯一逻辑源（平台无关）
│   ├── core-logic.md     #   四步法逻辑/编号/绑定/循环/基线/违规
│   └── binding-recommendation.md  # 按步骤特性推荐后端
├── SKILL.md              # Hermes 适配层（run_cli.py + binding-lock.json）
├── opencode/             # opencode 适配层
└── dsh/                  # DeepSeek Harness 适配层（本目录）
    ├── SKILL.md          #   DSH 编排规则（主交付物，安装为 DSH skill）
    ├── agents/           #   subagent 提示词模板（orchestrator/explorer/auditor/planner/implementer/verifier + vision-reviewer 视觉兜底）
    ├── scripts/          #   manage_binding.ps1（绑定管理）+ run_step.ps1（统一分派入口）
    ├── binding-lock.json #   绑定锁模板（默认 step1/2/3/4=dsh-sub）
    ├── DYNAMIC-DELEGATION.md # 动态拆分与并行边界（DSH 版）
    └── README.md
# 共享视觉 runner 位于 opencode/scripts/run_vision_review.ps1（DSH 与 opencode 共用，逻辑见 shared/core-logic.md §11）
```

**规则**：逻辑优化只改 `shared/` 一次，三个适配层只更新引用；平台细节（subagent 调度、CLI 调用、权限、队列）各自独立进化。

## 与 Hermes/opencode 的执行差异

| 维度 | opencode | DSH（本目录） |
|------|----------|---------------|
| subagent 创建 | 预定义 agents/*.md + Task 工具 | 运行时用 `subagent` 工具 + `dsh/agents/*.md` 提示词模板 |
| 权限隔离 | `permission: edit: deny`（系统级） | 无系统级权限字段；靠提示词强制只读 + 事后 `git diff > baseline.diff` 回退 |
| 后端绑定 | opencode-sub / CLI | dsh-sub / CLI（CLI runner 复用 opencode/scripts/） |
| 绑定锁路径 | `~/.config/opencode/harness/binding-lock.json` | `~/.dsh/harness/binding-lock.json`（env `DSH_BINDING_LOCK`） |
| 模型族 | opencode-sub 固定族 | `binding-lock.json` 的 `models` 字段决定 dsh-sub 的族；step4≠step3 必须不同族 |

## 安装到 DeepSeek Harness

### 1. 安装 DSH skill（二选一）

**方式 A：用户级（推荐，所有项目可用）**

```
~/.dsh/skills/harness-4step/SKILL.md        ← 复制自 dsh/SKILL.md
~/.dsh/skills/harness-4step/scripts/        ← 复制自 dsh/scripts/（manage_binding.ps1、run_step.ps1）
~/.dsh/skills/harness-4step/agents/         ← 复制自 dsh/agents/
```
视觉审查共享 runner `opencode/scripts/run_vision_review.ps1`（shared/core-logic.md §11）需一并复制到 scripts/（mimo CLI 需已装并登录）。

**方式 B：项目级（仅该项目可用）**：把上述内容放到 `<项目根>/.dsh/skills/harness-4step/`。DSH 会按 cwd 扫描项目技能目录。

### 2. 安装绑定锁到本机

绑定是本机私有配置，不上传仓库；`manage_binding.ps1` 是其唯一读写入口：

```powershell
& "$HOME\.dsh\skills\harness-4step\scripts\manage_binding.ps1" -InstallFromRepo
& "$HOME\.dsh\skills\harness-4step\scripts\manage_binding.ps1" -Check
```

绑定变更必须经 `manage_binding.ps1 -AuthorizeStep <step> -Agent <agent> -Authorization "<用户授权原文>"` 完成并写入授权日志；禁止手改 lock 绕过。

### 3. 配置模型族（step4 ≠ step3）

编辑本机 `~/.dsh/harness/binding-lock.json` 的 `models` 字段，给 step4 配置与 step3 **不同模型族**的模型（如 step3 用 DeepSeek、step4 用 Claude/Codex 或其他 provider）。这决定 `subagent` 工具创建 step3/step4 subagent 时的 `provider`/`model` 覆盖。`manage_binding.ps1 -Check` 会强制校验族不同。

### 4. 让 subagent 能读取共享逻辑（只引用不复制）

**不要复制 `shared/` 到别处** —— `shared/` 是唯一逻辑源（shared/core-logic.md §10），复制会造成副本与源头分叉。读取方式二选一：

- **方式 A（推荐）**：用 DSH 打开**仓库根目录**作为工作区运行四步法。各 subagent 用 read 工具按相对路径 `shared/core-logic.md` 读取（每个 agents/*.md 模板已含"运行时读取共享逻辑"前置动作）。
- **方式 B（仓库外运行）**：设置环境变量 `HARNESS_SHARED_DIR=<仓库绝对路径>/shared`，各 subagent 读取 `$env:HARNESS_SHARED_DIR\core-logic.md`。该变量只是指向仓库内 shared/ 的引用路径，不产生副本。

### 5. 使用

在 DSH 会话中加载技能（`skill` 工具加载 `harness-4step`），然后按 `dsh/SKILL.md#编排流程` 执行。主 agent 用 `subagent` 工具调度每一步。

> 注意：四步法必须在仓库根目录作为 DSH 工作区打开（方式 A），或设置 `HARNESS_SHARED_DIR`（方式 B），subagent 才能在运行时通过 read 工具拿到 `shared/core-logic.md` 内容。两者都没有时，subagent 会提示调度者，不会凭空臆造共享逻辑。

## 视觉审查（四步法内部视觉兜底，shared/core-logic.md §11）

主模型（如 deepseek-v4-flash）与四步法各步绑定后端（DSH subagent）默认无视觉时，当某步需要"看图"（step1 审截图 / step3 核对 UI 效果 / step4 对比 before-after）经本能力处理。**不是独立功能，是四步法内部的跨步视觉兜底**（不是第五步）；Hermes 自带视觉不触发，DSH 与 opencode 支持。

- **机制**：主 agent → `subagent` 调 `vision-reviewer` → pwsh 调共享 runner `opencode/scripts/run_vision_review.ps1` → mimo CLI + 视觉模型（默认 `xiaomi/mimo-v2.5`）看图 → 返回结构化文本结论（作为该步输入佐证）。
- **共享脚本**：`opencode/scripts/run_vision_review.ps1`（DSH 与 opencode 共用，逻辑见 shared/core-logic.md §11；`-ImageFiles` 必填，可多张；`-Model` 默认 `xiaomi/mimo-v2.5`；产物 `vision-review.md`）。从仓库根目录调用；DSH 侧经 `../../opencode/scripts/` 引用。
- **agent 模板**：`dsh/agents/vision-reviewer.md`。
- **前提**：本机已装并登录 mimo CLI（`references/mimo-cli-login.md`；`mimo providers whoami` 输出 Provider: MiMo）。
- **只读保证**：只写 `.harness/<task>/vision/` 产物，不碰目标代码；视觉结论以 mimo 输出为准，打不开/超时/失败一律如实报告 `blocked`，禁止虚构。

```powershell
# 直接调用示例（也可经 vision-reviewer subagent 间接调用）
powershell -NoProfile -Command "& '<repo>\opencode\scripts\run_vision_review.ps1' -ImageFiles '<img1>','<img2>' -Prompt '对比前后视觉差异' -WorkspaceDir '<repo>' -OutDir '<repo>\.harness\<task>\vision'"
```

## 验证

```powershell
# 绑定校验（fail-closed）
& "$HOME\.dsh\skills\harness-4step\scripts\manage_binding.ps1" -Check
# 应输出每步绑定 + 模型族 + BINDING_LOCK_OK
```

DSH 加载 `harness-4step` skill 后，会话技能目录应出现 `harness-4step`（用户级或项目级来源）。

## 跨模型差异

绑定为 `dsh-sub` 时，每步模型由 `binding-lock.json` 的 `models` 配置决定（step1/2 可用强分析模型、step3 可用快模型、step4 用与 step3 不同族的模型）；绑定为 CLI 后端（claude/codex/mimo）时，模型由各 CLI 侧配置。**Step 4 与 Step 3 必须不同模型族**（`shared/core-logic.md` §4；每次绑定校验由 `manage_binding.ps1 -Check`/`-AuthorizeStep` 强制）。

## 维护

- `shared/` 变更 → 三个平台自动同步（各自引用）
- DSH 适配层变更 → 只影响 DSH；Hermes/opencode 侧不受影响
- CLI runner（`run_claude_step12.ps1` 等）与 opencode 共享，修改时两适配层同时生效
