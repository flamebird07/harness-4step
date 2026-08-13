# 后端绑定推荐表（共享）

> **仅推荐，不强制**。实际绑定以各平台绑定配置为准（Hermes: `~/.hermes/binding-lock.json`；opencode: `~/.config/opencode/harness/binding-lock.json`，经 `manage_binding.ps1` 管理）。
> 核心约束：**Step 4 与 Step 3 必须不同模型族**，其余按可用性与成本取舍。

## 可选后端清单

| 后端标识 | 类型 | 命令/机制 | 免费 | 中文 | 适用步骤 | 备注 |
|---------|------|-----------|------|------|---------|------|
| `claude` | CLI | `claude -p` / Step3 带 `--dangerously-skip-permissions` | ❌ | ★★★★★ | 1/2/3/4 | 通用强，Step1/2 首选 |
| `codex` | CLI | `codex exec --ephemeral --sandbox danger-full-access --json`（`CODEX_HOME=~/.ccsc/codex-mimo`） | ❌ | ★★★★ | 1/2/4 | Step4 常用，跨模型族；默认 `~/.codex` 可能失效，用隔离的 CODEX_HOME 更稳 |
| `mimo` | CLI | `mimo run --print-logs -m xiaomi/mimo-v2.5-pro` | ✅ | ★★★★★ | 1/2/3 | 免费，Step3 省钱首选 |
| `kimi` | CLI | `kimi -p` | 未知 | ★★★★★ | 1/2 | `--plan` 适合 Step2 |
| `gemini` | CLI | `gemini "prompt"` | 部分 | ★★★★★ | 1/4 | 跨模型族（opencode 分派器不支持：manage_binding/run_step 已去 gemini） |
| `opencode-sub` | subagent | opencode 内 `harness-*` subagent，可配 model | 视 model | — | 1/2/3/4 | 权限系统级隔离 |

## 按步骤推荐

| 步骤 | 特性 | 首选 | 备选 | 理由 |
|------|------|------|------|------|
| Step 1 审查 | 深度读码、找缺陷、只读 | claude / codex / opencode 高智力 model | kimi | 需要强理解和批判性 |
| Step 2 方案 | 精确 before/after 规划、只读 | claude / codex | kimi(plan) | 需要精确生成可替换片段 |
| Step 3 执行 | 精确改码、重 token、可写文件 | **mimo（省钱）** / opencode-harness-implementer | claude | 便宜 + 权限隔离；避免最贵模型跑机械活 |
| Step 4 复审 | **必须与 Step3 不同模型族**、挑盲区 | codex | claude | 跨模型族才能抓出执行者的惯性盲区 |

## 组合示例（复制到各自绑定配置）

```
省钱组合:  Step1=claude  Step2=claude     Step3=mimo            Step4=codex
加强组合:  Step1=claude  Step2=kimi-plan  Step3=opencode-sub    Step4=codex
全本地opencode: Step1/2/4=opencode-sub(强model)  Step3=opencode-sub(快model)
```

## 注意

- Step 4 应用不同模型族避免盲区（本表默认已保证）
- 绑定变更 = 用户显式授权，不得为"内容修复质量"而切绑定（那是走 Step 2→3→4 循环的职责）
- opencode 绑定为 CLI 后端时模型由 CLI 侧配置；若绑定 `opencode-sub`，可给 `harness-auditor/planner` 配更强 model、给 `harness-implementer` 配更快 model，构成跨模型族（step4 与 step3 必须不同族，由 manage_binding.ps1 校验）