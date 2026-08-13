# 4步法强制执行系统 (Harness 4-Step Method)

> **v13.0.16** — 绑定锁 + 原子队列 + 递归拆分；每步 CLI 绑定由 binding-lock.json 决定（Hermes 与 opencode 各自持久化）。单一项目兼容 Hermes/opencode，共享逻辑在 `shared/`。

## 系统组成

| 组件 | 作用 |
|------|------|
| shared/ | **唯一逻辑源**：core-logic.md（四步法逻辑）+ binding-recommendation.md（推荐表） |
| SKILL.md | Hermes 适配层：定义4步法规则和流程（v13.0.16） |
| opencode/ | opencode 适配层：SKILL.md + 4 个 harness-* subagents + README |
| plugin/ | harness-4step 技术强制执行插件 |
| references/ | 参考文档（CLI 语法、故障诊断、会话取证） |
| scripts/ | 工具脚本 |

## 支持的 CLI

| CLI | 基础命令 | output_parse | step3 特殊处理 | 已知坑 |
|-----|---------|--------------|---------------|--------|
| Codex | `codex exec --ephemeral --skip-git-repo-check --sandbox danger-full-access --json` | json_lines | 移除 `--ephemeral`（保留会话） | JSON 解析失败会误报 |
| Claude Code | `claude -p` | plain | 移除 `-p`，加 `--dangerously-skip-permissions` | step3 需权限参数 |
| Kimi Code | `kimi -p` | plain | 无 | `-p` 参数不读 stdin，必须 use_stdin=false |
| Mimo Code | `mimo run --print-logs -m xiaomi/mimo-v2.5-pro` | plain | 无 | step3 prompt 加保护前缀（避免自跑测试） |

绑定由 `~/.hermes/binding-lock.json` 决定，变更需 `--authorize-binding-change` 授权。

## 4步法流程

| 步骤 | Agent（绑定由 binding-lock.json 决定） | Real CLI | 超时 | 限制 |
|------|--------------------------------------|----------|------|------|
| Step 1 | 由 binding-lock.json 决定 | `run_cli.py --step step1` | 120s | 只审查，不能改代码 |
| Step 2 | 由 binding-lock.json 决定 | `run_cli.py --step step2` | 120s | 只出方案，不能改代码 |
| Step 3 | 由 binding-lock.json 决定 | `run_cli.py --step step3` | 300s | 按方案执行修改，不能做方案/审查 |
| Step 4 | 由 binding-lock.json 决定 | `run_cli.py --step step4` | 180s | 复审，不能改代码 |

**核心原则：每步 CLI 绑定后不可更改。** 绑定以 `binding-lock.json` 为准，用户设定后永久锁定；CLI 失败/超时按「超时处理与降级路径」规则处理（先精简重试，再走降级路径，降级必须声明，见 SKILL.md），绑定本身不因超时改变。绑定变更必须通过用户显式授权路径（`--authorize-binding-change`）完成，禁止直接改文件绕过；`harness-config.yaml` 不能改 agent。

**Step 1 每次执行时除常规审查外，必须扫描项目中所有文件版本号并比对一致性**，不一致项作为 finding 纳入 Step 2 方案修复——不一致但未报告 = Step 1 验证失败。

**循环机制**：Step 4 发现问题 → 回到 Step 2 → Step 3 → Step 4，默认最多 3 轮（可配置到 10，见 shared/core-logic.md）。

## To-Do 队列与自动拆分

每个任务都有 `~/.hermes/harness-workspace/<task-id>/todo.json`。队列只允许原子问题：一个验收目标、明确文件范围、可独立验证。同一只读步骤第二次失败/超时，item 自动标记 `split_required`，必须拆成子项。所有待办清零并通过总审查，才算完工。

### 队列常用命令

| 命令 | 作用 |
|------|------|
| `--todo-init <标题>` | 初始化队列 |
| `--todo-add <ITEM_JSON>` | 加入一个 item |
| `--todo-next` | 领取下一个可执行 item（设为 running） |
| `--todo-split <父ID> --todo-children <CHILDREN_JSON>` | 把 item 拆成子项 |
| `--todo-finish <ID> --todo-state <completed\|blocked>` | 完成/阻塞 item |
| `--todo-list` | 查看队列状态 |
| `--todo-recover <ID>` | 恢复孤儿 running item 为 pending（保留 `split_required`） |

## 快速开始

### 1. 安装技能

```bash
cp -r harness-4step ~/.hermes/skills/
```

### 2. 安装插件（可选，技术强制执行）

```bash
cp -r plugin ~/.hermes/plugins/harness-4step
```

### 3. 使用

在 Hermes 对话中加载技能：
```
/skill harness-4step
```

## 版本历史

- v13.0.16 (2026-08-13): opencode 融合后加固：run_step.ps1 claude 分支 step-aware 超时（step3→300、step1/2→120）；codex/mimo/kimi step4 回退 300→180；opencode-sub 改权威分派契约（输出 BINDING/STEP/SUBAGENT + 出口码 99，未消费视为未完成）；harness-orchestrator "直接处理"限定只读；DYNAMIC-DELEGATION 新增"与 CLI 绑定分派（线B）的关系" + 调度表只读限定；verifier 兜底措辞澄清。版本号 13.0.15 → 13.0.16。
- v13.0.15 (2026-08-13): opencode 适配层绑定 fail-closed 加固：manage_binding.ps1 / run_step.ps1 受支持 agent 统一为 claude/codex/mimo/kimi/opencode-sub（去 gemini）；run_step.ps1 分派前校验 schema/locked/完整绑定/受支持 agent/step3≠step4 模型族；manage_binding.ps1 补 step1/2 受支持校验；run_codex_step4.ps1 用 -C 传 WorkspaceDir 给 codex exec；kimi 文档对齐（-p 位置参数 + 8191 截断）；README 安装清单补 run_step.ps1 / run_kimi_step4.ps1。版本号 13.0.14 → 13.0.15。
- v13.0.14 (2026-08-13): opencode 编排动态分派：新增 run_step.ps1 统一入口（读 binding-lock.json 分派到 claude/codex/mimo/kimi，opencode-sub 输出信号改走 subagent）；新增 run_kimi_step4.ps1；step4 只读前缀裁决为只读核对；run_claude_step12.ps1 修复 stdin UTF-8 + --add-dir。版本号 13.0.13 → 13.0.14。
- v13.0.13 (2026-08-13): opencode 适配层绑定升级：新增 opencode/binding-lock.json + manage_binding.ps1（显式授权/校验）；step1/2/3 默认绑定 Claude Code CLI（用户显式授权）、step4=codex 保持不同模型族；mimo 脚本 -f 文件模式 + 前缀；三个 ps1 统一超时部分输出与失败信号。版本号 13.0.12 → 13.0.13。
- v13.0.12 (2026-08-10): 新增跨平台架构：共享逻辑唯一源 `shared/core-logic.md` + 推荐表 `shared/binding-recommendation.md`；新增 `opencode/` 适配层（SKILL.md + harness-* subagents + scripts）；废弃旧 four-step-harness 并入本项目。
- v13.0.11 (2026-08-09): 新增子项并行执行（delegate_task 派发多子 Agent 同时跑各自 4 步法）；新增拆分边界规则（最小粒度、最大深度 3 层、BLOCKED_SPLIT_LIMIT）；split 事件必填 reason 字段。
- v13.0.10 (2026-08-09): 修复 harness-config.yaml steps 段硬编码 agent 绑定导致的跨实例兼容缺陷。移除 steps 段的 agent 字段，完全由 binding-lock.json 控制。
- v13.0.9 (2026-08-09): DEFAULT_CONFIG 不再含 agent，binding-lock.json 唯一绑定来源（隐私解耦）；mimo 修复（prompt_mode=file、use_stdin=false）；apply_step_prompt_prefix helper；auto-enqueue-findings；fix-codex-step4；plugin v3.0.0 独立版本化；违规清单第5项加宽。
- v13.0.8 (2026-08-09): CLI 绑定 relock — Step 1 绑定 mimo → codex，Step 4 绑定 mimo → kimi。版本号 13.0.7 → 13.0.8。
- v13.0.7 (2026-08-09): 新增「跨session上下文断裂/Windows命令行参数截断/Step3必须产生diff」三坑 Pitfall 章节；版本号 13.0.6 → 13.0.7。
- v13.0.6 (2026-08-05): 修复 run_cli.py 中 Claude CLI 的 `--dangerously-skip-permissions` 对所有步骤生效的违规：`args_extra` 重命名为 `step3_extra_args`，仅在 Step 3 时添加。Step 1/2 为只读步骤，不应有文件修改权限。版本号 13.0.5 → 13.0.6。
- v13.0.5 (2026-08-05): Step 1 新增版本号一致性审查：每次执行时扫描所有文件版本号并比对，不一致项纳入 Step 2 方案修复。版本号 13.0.4 → 13.0.5。
- v13.0.4 (2026-08-05): 4 项强化：绑定锁后新增诊断优先规则；Step 2 技术只读保障强化为显式禁止文件修改+git 验证+失败处理；CLI 超时处理新增 exit 124 必重试规则；失败分类矩阵后新增强制分类规则。
- v13.0.3 (2026-08-04): Step1 绑定改为 mimo；CLI 选项内嵌到 AGENT_CLI；绑定变更通过单一 --authorize-binding-change 命令完成；版本号 13.0.2 → 13.0.3。
- v13.0.2 (2026-08-04): 新增「拆分优化」「违规记录规范」两节；版本号 13.0.1 → 13.0.2。
- v13.0.1 (2026-08-04): 新增版本号规则（每次修改只递增 patch 位）；Step4 绑定从 kimi 改为 mimo（mimo-v2.5-pro）。
- v13.0.0 (2026-08-04): 修复实际插件被全量豁免且未启用、CLI 配置可静默漂移的根因；新增 binding-lock、原子 to-do 状态机、二次只读失败强制拆分、每步报告、直接 CLI/直接写入反绕过门禁，并启用 four-step-enforcer。

## 许可证

MIT
