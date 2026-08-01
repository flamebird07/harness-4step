# 4步法强制执行系统 (Harness 4-Step Method)

> **v12.17.0** — Step 1/2/3 全部使用 Codex CLI，Step 4 使用 Kimi CLI；递归拆分由持久化 To-Do 队列执行

## 系统组成

| 组件 | 作用 |
|------|------|
| SKILL.md | 定义4步法规则和流程（v12.16.0） |
| plugin/ | harness-4step 技术强制执行插件 |
| references/ | 参考文档（CLI 语法、故障诊断、会话取证） |
| scripts/ | 工具脚本 |

## 4步法流程

| 步骤 | Agent（固定绑定） | Real CLI | 超时 | 限制 |
|------|-----------------|----------|------|------|
| Step 1 | **Codex CLI**（不可更改） | `codex exec --ephemeral` | 120s | 只审查，不能改代码 |
| Step 2 | **Codex CLI**（不可更改） | `codex exec --ephemeral` | 120s | 只出方案，不能改代码 |
| Step 3 | **Codex CLI**（不可更改） | `codex exec -s danger-full-access` | 120s | 按方案执行修改，不能做方案/审查 |
| Step 4 | **Kimi CLI**（不可更改） | `kimi -p` | 180s | 复审，不能改代码 |

**核心原则：每步 CLI 绑定后不可更改。** 用户设定后，该步的 CLI 工具永久固定，超时只重试不降级，不自动匹配历史使用过的其他 CLI。

**循环机制**：Step 4 发现问题 → 回到 Step 2 → Step 3 → Step 4，最多 10 轮。

## To-Do 队列与自动拆分

每个任务都有 `~/.hermes/harness-workspace/<task-id>/todo.json`。队列只允许原子问题：一个验收目标、明确文件范围、可独立验证。出现第二次超时或范围仍过大时，当前项必须拆成子项，子项继续排队；所有待办清零并通过总审查，才算完工。

```bash
python scripts/run_cli.py --task-id order-42 --todo-init "修复订单流程"
python scripts/run_cli.py --task-id order-42 --todo-add-file order-api.json
python scripts/run_cli.py --task-id order-42 --todo-next
python scripts/run_cli.py --task-id order-42 --todo-list
```

`order-api.json` 保存该待办的 JSON。Windows 环境优先使用文件参数，避免 PowerShell 改写长 JSON 参数。

## 快速开始

### 1. 安装技能

```bash
# 将 SKILL.md 及关联文件复制到 Hermes skills 目录
cp -r harness-4step ~/.hermes/skills/
```

### 2. 安装插件（可选，技术强制执行）

```bash
# 复制插件到正确位置
cp -r plugin/harness-4step ~/.hermes/plugins/
```

### 3. 使用

在 Hermes 对话中加载技能：

```
/skill harness-4step
```

## 版本历史

- v12.17.0 (2026-08-01): 修正 Step 3 默认超时为执行器实际值 300 秒。
- v12.16.0 (2026-08-01): 新增执行器支持的持久化 To-Do 队列、递归拆分及超时部分输出保留；统一默认 CLI 绑定。

- v12.15.0 (2026-08-01): Step 1/2/3 全部使用 Codex CLI，Step 4 保留 Kimi CLI；插件重命名为 harness-4step
- v12.14.0 (2026-08-01): 通用化递归拆分与总审查规则；跨文件原子 loop、拓扑排序
- v12.13.0 (2026-07-31): 递归拆分机制：大问题→子问题→原子级 to-do 项
- v12.12.0 (2026-07-31): Step 1 → Kimi CLI（审查），Step 2 → Codex CLI（方案）
- v12.10.0 (2026-07-31): 多问题拆分为独立 loops 排队修复
- v12.9.0 (2026-07-30): 强化 self-audit 门禁，harness-4step-repo 移出 skills/
- v12.8.0 (2026-07-30): 添加 Kimi CLI Windows `.cmd` 包装器陷阱
- v12.7.0 (2026-07-30): Step 2 和 Step 4 统一使用 Kimi CLI，移除 MiMo Code
- v12.6.0 (2026-07-30): 每步 CLI 绑定不可更改，超时只重试不降级

## 许可证

MIT
