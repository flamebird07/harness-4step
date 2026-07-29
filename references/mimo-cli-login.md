# MiMo Code CLI 登录流程

## 概览

MiMo Code CLI (`mimo`) 提供两种登录方式：免费通道和付费（浏览器 OAuth）登录。

## 命令

```bash
mimo providers login          # 交互式 TUI 菜单
mimo providers login -p mimo  # 跳过菜单，自动选免费通道
mimo providers list           # 查看已配置的 credentials
mimo providers whoami         # 查看当前登录状态
mimo providers logout         # 退出登录
```

## 免费通道（无需浏览器）

```bash
mimo providers login --provider mimo
```

自动选择 MiMo Auto (free) 通道，输出：
- Endpoint: `https://api.xiaomimimo.com/api/free-ai/openai/chat`
- Token exp: 短时效（约 5 分钟）
- 默认模型切换为 `mimo/mimo-auto`

**注意**：免费通道的 `mimo/mimo-auto` 模型当前返回 `Error: Unsupported model mimo-auto`，不可用。

## 付费登录（浏览器 OAuth）

```bash
mimo providers login
```

交互式 TUI 菜单：
```
◆  选择服务商
│  ● MiMo (推荐)     ← 默认选中，按 Enter
│  ○ MiMo Auto (free)
│  ○ 其他 Provider
```

选择后输出 OAuth URL：
```
●  Browser didn't open? Use the url below to sign in:
│  https://platform.xiaomimimo.com/authorize?pk=<key>&redirect_uri=...&kn=mimocode&key_name=mimo-code-cli-key-31a1eace
Paste code here if prompted >
```

需要在浏览器打开该 URL 完成登录，然后终端会收到验证。

## 可用模型

```bash
mimo models
```

输出示例：
```
anthropic/claude-sonnet-4-5
mimo/mimo-auto
xiaomi/mimo-v2.5
xiaomi/mimo-v2.5-pro
```

## 已知问题

| 模型 | 状态 |
|------|------|
| `mimo/mimo-auto` | ❌ Unsupported model（免费通道不可用） |
| `xiaomi/mimo-v2.5` | ❌ Invalid API Key（需付费登录） |
| `xiaomi/mimo-v2.5-pro` | ❌ Invalid API Key（需付费登录） |
| `anthropic/claude-*` | ❌ Error: empty output（依赖 ANTHROPIC_API_KEY 环境变量） |

## 凭证存储位置

- auth.json: `~/.local/share/mimocode/auth.json`
- 免费 token fingerprint: `~/.local/share/mimocode/mimo-free-client`
- key name: `~/.local/share/mimocode/mimo-key-name`
- 数据库: `~/.local/share/mimocode/mimocode.db`

## 注意事项

- 免费 token 短时效，需频繁重新登录
- `--provider mimo` 会跳过菜单直接选免费通道
- 浏览器登录是交互式的，自动化困难
- 登录状态不跨机器共享
