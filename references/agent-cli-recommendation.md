# Agent CLI 推荐表（2026年7月）

> **完整指南见 `agent-cli-guide.md`**
> 本文件为快速参考摘要。

## 主流 Agent CLI（无头模式）

| CLI            | 命令                              | 免费 | 中文 | 适用步骤     |
|----------------|----------------------------------|------|------|-------------|
| Codex CLI      | `codex exec "prompt"`            | ❌   | ★★★★ | 1/2/4       |
| Claude Code    | `claude -p "prompt"`             | ❌   | ★★★★★| 1/2/3/4     |
| MiMo Code      | `mimo run -m mimo/mimo-auto "prompt"` | ✅ | ★★★★★| 1/2/3       |
| Kimi K3        | `kimi -p "prompt"` / `kimi --plan` | 未知 | ★★★★★| 1/2         |
| Gemini CLI     | `gemini "prompt"`                | 部分 | ★★★★★| 1/4         |
| Aider          | `aider --yes --message "prompt"` | ❌   | ★★★★ | 3           |
| Hermes patch   | `patch()` / `write_file()`       | ✅   | -    | 3（仅修改）  |

## 快速选择

- **省钱**: MiMo(1/2) + Hermes(3) + Codex(4)
- **加强**: Kimi K3(1/2) + MiMo(3) + Gemini(4)
- **当前**: Codex(1/2/4) + Hermes(3)

## 注意

- Step 4 应用不同模型族避免盲区
- Kimi K3 `--plan` 模式适合 Step 2
- MiMo Code 比 Hermes patch 强（能读代码+验证）
