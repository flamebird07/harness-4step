# MiMo Code CLI 登录与使用指南

## 概览

MiMo Code CLI (`mimo`) 提供两种登录方式：免费通道和付费（浏览器 OAuth）登录。

## Windows PATH 坑（重要）

`mimo` 安装在 npm 全局目录，**不在默认 PATH 中**。每次调用前必须：

```bash
export PATH="$PATH:/c/Users/Administrator/AppData/Roaming/npm"
```

验证：
```bash
mimo providers whoami
# 应输出: Provider: MiMo
```

## 命令

```bash
mimo providers login          # 交互式 TUI 菜单
mimo providers login -p mimo  # 跳过菜单，自动选免费通道
mimo providers list           # 查看已配置的 credentials
mimo providers whoami         # 查看当前登录状态
mimo providers logout         # 退出登录
mimo models                   # 列出所有可用模型
```

## 基本语法

```bash
mimo run --model xiaomi/mimo-v2.5 "<message>"
```

- `message` 是 positional argument，直接在选项后输入
- `--command` 用于 predefined 命令（init, review, dream, goal 等），不能用于自由消息
- 模型命名规则：`provider/model` 格式

## 付费登录（浏览器 OAuth）— 当前可用方式

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

选择后输出 OAuth URL，需要在浏览器打开该 URL 完成登录，然后终端会收到验证。

## 可用模型状态（2026-07-30 验证）

```bash
mimo models
```

| 模型 | 状态 | 备注 |
|------|------|------|
| `xiaomi/mimo-v2.5` | ✅ 可用 | 需付费登录（MiMo Provider） |
| `xiaomi/mimo-v2.5-pro` | ✅ 可用 | 需付费登录 |
| `mimo/mimo-auto` | ❌ Unsupported model | 免费通道不可用 |
| `anthropic/claude-*` | 需 ANTHROPIC_API_KEY | 依赖环境变量 |

## 超时处理与分文件执行技巧

MiMo 对大文件修改容易超时（180s）。**核心技巧：按文件分拆执行**。

```
❌ 一次性让 MiMo 改3个文件 → 180s 超时，无任何改动
✅ 分3次调用，每次只改1个文件 → 全部成功
```

**最佳实践**：
- 每次调用只让 MiMo 改一个文件
- prompt 尽量简短（<2000 字符）
- 明确给出文件名、行号、旧代码、新代码
- 3个文件分3次调用即可成功

**示例**：
```bash
# 第1次：改 switch_next.py
mimo run --model xiaomi/mimo-v2.5 "In switch_next.py: change identity() at line 128 to return (model.lower(), api_key.strip(), normalise_base_url(base_url))."

# 第2次：改 cleanup_feishu_status.py
mimo run --model xiaomi/mimo-v2.5 "In cleanup_feishu_status.py: change identity() signature to (model, api_key, base_url)..."

# 第3次：改 sync_credential_pool.py
mimo run --model xiaomi/mimo-v2.5 "In sync_credential_pool.py: add identity() function after normalise_base_url()..."
```

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
- 重启后可能需要重新 `mimo providers login`
