# Agent CLI 推荐表（2026年7月）

> **完整指南见 `agent-cli-guide.md`**
> 本文件为快速参考摘要。

## 主流 Agent CLI（无头模式）

| CLI            | 命令                              | 免费 | 中文 | 适用步骤     |
|----------------|----------------------------------|------|------|-------------|
| Codex CLI      | `codex exec "prompt"`            | ❌   | ★★★★ | 1/2/4       |
| Claude Code    | `claude -p "prompt"`             | ❌   | ★★★★★| 1/2/3/4     |
| MiMo Code      | `mimo run -m xiaomi/mimo-v2.5-pro "prompt"` | ✅ | ★★★★★| 1/2/3       |
| Kimi K3        | `kimi -p "prompt"` / `kimi --plan` | 未知 | ★★★★★| 1/2         |
| Gemini CLI     | `gemini "prompt"`                | 部分 | ★★★★★| 1/4         |
| Aider          | `aider --yes --message "prompt"` | ❌   | ★★★★ | 3           |

## 快速选择

- **省钱**: MiMo(1/2/3) + Codex(4)
- **加强**: Kimi K3(1/2) + MiMo(3) + Gemini(4)
- **当前**: 由 binding-lock.json 决定（示例：Codex(1/2/4) + MiMo(3)）

## 注意

- Step 4 应用不同模型族避免盲区
- Kimi K3 `--plan` 模式适合 Step 2
- Step 3 不能用 Hermes patch/write_file——会被 four-step-enforcer 插件无条件拦截；MiMo Code 能读代码+验证
