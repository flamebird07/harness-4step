# 4步法强制执行系统 (Harness 4-Step Method)

> **v13.0.9** — 绑定锁 + 原子队列 + 递归拆分；每步 CLI 绑定由 binding-lock.json 决定

## 系统组成

| 组件 | 作用 |
|------|------|
| SKILL.md | 定义4步法规则和流程（v13.0.9） |
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

**核心原则：每步 CLI 绑定后不可更改。** 绑定以 `binding-lock.json` 为准，用户设定后永久锁定，超时只重试不降级。绑定变更必须通过用户显式授权路径（`--authorize-binding-change`）完成，禁止直接改文件绕过；`harness-config.yaml` 不能改 agent。

**Step 1 每次执行时除常规审查外，必须扫描项目中所有文件版本号并比对一致性**，不一致项作为 finding 纳入 Step 2 方案修复——不一致但未报告 = Step 1 验证失败。

**循环机制**：Step 4 发现问题 → 回到 Step 2 → Step 3 → Step 4，最多 10 轮。

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
cp -r plugin/harness-4step ~/.hermes/plugins/
```

### 3. 使用

在 Hermes 对话中加载技能：
```
/skill harness-4step
```

## 版本历史

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
