# opencode 适配层（Harness 4-Step Method）

单一项目 `flamebird07/harness-4step`，同时兼容 Hermes、opencode 与 DeepSeek Harness (DSH)。本目录是 opencode 侧实现。

## 架构

```
harness-4step/            # GitHub 仓库（同一仓库）
├── shared/               # 唯一逻辑源（平台无关）
│   ├── core-logic.md     #   四步法逻辑/编号/绑定/循环/基线/违规
│   └── binding-recommendation.md  # 按步骤特性推荐后端
├── SKILL.md              # Hermes 适配层（run_cli.py + binding-lock.json）
├── opencode/             # opencode 适配层（本目录）
│   ├── SKILL.md          #   编排规则
│   ├── agents/           #   1 个主编排 agent + 5 个权限隔离的 subagent
│   ├── opencode.json     #   动态编排项目配置模板
│   ├── DYNAMIC-DELEGATION.md # 动态拆分与并行边界
│   └── README.md
└── dsh/                  # DeepSeek Harness 适配层（dsh/SKILL.md + agents + scripts）
```

**规则**：逻辑优化只改 `shared/` 一次，各适配层只更新引用；平台细节（CLI 调用、subagent 权限、队列）各自独立进化。

## 安装到 opencode

1. 复制 skill 到全局 skill 目录：

   ```
   ~/.config/opencode/skill/four-step-harness/SKILL.md   ← 复制自 opencode/SKILL.md
   ```

2. 复制主编排 agent 与 5 个 subagent 到全局 agents 目录：

   ```
   ~/.config/opencode/agents/harness-orchestrator.md
   ~/.config/opencode/agents/harness-explorer.md
   ~/.config/opencode/agents/harness-auditor.md
   ~/.config/opencode/agents/harness-planner.md
   ~/.config/opencode/agents/harness-implementer.md
   ~/.config/opencode/agents/harness-verifier.md          ← 复制自 opencode/agents/
   ```

2b. 把 `opencode/opencode.json` 的 `default_agent` 与 `subagent_depth` 合并到目标项目根目录的 `opencode.json`。它不指定模型，不会覆盖已有模型配置。

2c. 复制 CLI 脚本到 skill 目录（SKILL.md 编排依赖，不可省略）：

   ```
   ~/.config/opencode/skill/four-step-harness/scripts/   ← 复制自 opencode/scripts/（run_step.ps1、run_claude_step12.ps1、run_codex_step4.ps1、run_mimo_step4.ps1、run_kimi_step4.ps1、manage_binding.ps1、step4_readonly_guard.ps1、run_vision_review.ps1）
   ```
   复制后 SKILL.md 中的调用路径 `<skill 目录>\scripts\run_codex_step4.ps1` 等即可用。
   run_step.ps1 是统一分派入口（读 binding-lock.json 调对应 runner）；run_claude_step12.ps1 是 step1/2/3（默认绑 claude CLI）的执行脚本；run_codex_step4.ps1 / run_mimo_step4.ps1 / run_kimi_step4.ps1 是 step4 及其备用；run_vision_review.ps1 是视觉审查共享 runner（shared/core-logic.md §11，DSH 也经它调用）。

2d. 复制绑定锁到本机（绑定是本机私有配置，不上传仓库；`manage_binding.ps1` 是其唯一读写入口）：

   ```
   ~/.config/opencode/harness/binding-lock.json          ← 复制自 opencode/binding-lock.json（默认绑定：step1/2/3=claude、step4=codex）
   ```
   绑定变更必须经 `manage_binding.ps1 -AuthorizeStep <step> -Agent <agent> -Authorization "<用户授权原文>"` 完成并写入授权日志；禁止手改 lock 绕过。

2e. （可选）复制超时配置模板到本机：

   ```
   ~/.config/opencode/harness/harness-config.json        ← 复制自 opencode/harness-config.example.json
   ```
   只允许覆盖 `defaults`/`steps` 的 `timeout_seconds` 与 `description`；**禁止加 agent 字段**（绑定只由 binding-lock.json 决定，防双配置源漂移）。
   编排时运行 `manage_binding.ps1 -ShowBindings` 查看合并后的绑定+超时，按需传 `-TimeoutSeconds`。

3. （可选）让 subagent 能读取共享逻辑（只引用不复制）：**不要复制 `shared/` 到别处**——
   `shared/` 是唯一逻辑源（shared/core-logic.md §10），复制会造成副本与源头分叉。读取方式二选一：
   - **方式 A（推荐）**：用 opencode 打开**仓库根目录**作为项目来运行四步法。agents 定义在全局
     `~/.config/opencode/agent/`，但其运行时工作目录 = 你打开的项目目录；cwd=仓库根 时，各 agent
     用 read 工具按相对路径 `shared/core-logic.md` 读取（每个 agent 正文已含"运行时读取共享逻辑"前置动作）。
   - **方式 B（仓库外运行）**：设置环境变量 `HARNESS_SHARED_DIR=<仓库绝对路径>/shared`，各 agent
     读取 `$HARNESS_SHARED_DIR/core-logic.md`。该变量只是指向仓库内 shared/ 的引用路径，不产生副本。

4. 重启 opencode。

> 注意：四步法必须在仓库根目录作为 opencode 项目打开（方式 A），或设置 `HARNESS_SHARED_DIR`（方式 B），
> agents 才能在运行时通过 read 工具拿到 `shared/core-logic.md` 内容。两者都没有时，agent 会提示调度者，
> 不会凭空臆造共享逻辑。

## 验证

`opencode agent list` 应出现 `harness-*`；选择 `harness-orchestrator` 后，复杂任务会先并行侦察、再按独立工作包进入四步闭环。完整调度规则见 [DYNAMIC-DELEGATION.md](DYNAMIC-DELEGATION.md)。

## 跨模型差异（可选）

绑定为 CLI 后端（claude/codex/mimo）时，模型由各 CLI 侧配置（如 `claude config` / `.coderc` / mimo `-m`）；
绑定为 `opencode-sub` 时，可在对应 `agents/*.md` frontmatter 加 `model:` 字段升级模型（审计/复审配强模型、执行配快模型）。
**Step 4 与 Step 3 必须不同模型族**（`shared/core-logic.md` §4；每次绑定校验由 `manage_binding.ps1 -Check`/`-AuthorizeStep` 强制，不做文字自我保证）。

## 维护

- `shared/` 变更 → 各平台自动同步（各自引用）
- opencode 适配层变更 → 只影响 opencode；Hermes 侧不受影响
