# 4步法强制执行系统 (Harness 4-Step Method)

> **v12.5.0** — Loop-Bypass Prevention + Self-Audit Hardening + Windows CLI 完整支持

## 系统组成

| 组件 | 作用 |
|------|------|
| SKILL.md | 定义4步法规则和流程（v12.5.0） |
| plugin/ | four-step-enforcer 技术强制执行插件 |
| references/ | 参考文档（CLI 语法、故障诊断、会话取证） |
| scripts/ | 工具脚本 |

## 4步法流程

| 步骤 | Agent | CLI 工具 | 超时 | 限制 |
|------|-------|----------|------|------|
| Step 1 | Codex CLI | `codex exec` | 120s | 不能改代码 |
| Step 2 | Codex CLI | `codex exec --ephemeral` | 120s | 只出方案，不能改代码 |
| Step 3 | Codex CLI | `codex exec -s danger-full-access` | 120s | 按方案执行修改 |
| Step 4 | MiMo Code / Kimi CLI | `mimo run` / `kimi -p` | 180s | 复审，不能改代码 |

**循环机制**：Step 4 发现问题 → 回到 Step 2 → Step 3 → Step 4，最多 10 轮。

## 快速开始

### 1. 安装插件

```bash
# 复制插件到正确位置
cp -r plugin/ ~/AppData/Local/hermes/plugins/four-step-enforcer/

# 启用插件
# 编辑 ~/AppData/Local/hermes/config.yaml，添加：
# plugins:
#   enabled:
#     - four-step-enforcer
```

### 2. 安装 Skill

```bash
# 复制整个技能目录到 skills 目录
cp SKILL.md ~/AppData/Local/hermes/skills/harness-4step/
cp -r references/ ~/AppData/Local/hermes/skills/harness-4step/
cp -r scripts/ ~/AppData/Local/hermes/skills/harness-4step/
```

### 3. 验证

```bash
# 检查插件加载
hermes plugins list

# 运行测试
cd ~/AppData/Local/hermes/plugins/four-step-enforcer
python test_four_step_enforcer.py
```

## 文件结构

```
harness-4step/
├── README.md                         # 项目介绍
├── SKILL.md                          # 技能定义 (v12.5.0, 36KB)
├── MIGRATION.md                      # 迁移说明
├── plugin/
│   ├── __init__.py                   # 插件主代码
│   ├── plugin.yaml                   # 插件元数据
│   └── test_four_step_enforcer.py    # 测试文件
├── references/
│   ├── codex-eftype-diagnosis.md     # Windows EFTYPE 错误诊断
│   ├── mimo-cli-login.md             # MiMo CLI 登录指南
│   ├── session-forensics.md           # 会话取证（4步法执行故障诊断）
│   ├── agent-cli-guide.md            # Agent CLI 指南
│   ├── agent-cli-recommendation.md   # Agent CLI 推荐
│   ├── b2-loop-patterns.md           # B2 循环模式
│   ├── b3-ocr-field-mapping.md       # B3 OCR 字段映射
│   ├── codex-document-verification.md # Codex 文档验证
│   ├── codex-ssh-calling-patterns.md  # Codex SSH 调用模式
│   ├── codex-step4-rereview.md        # Codex Step 4 复审
│   ├── frontend-backend-polling-sync.md # 前后端轮询同步
│   ├── pdd-development-workflow.md    # PDD 开发工作流
│   ├── windows-app-launcher.md       # Windows 应用启动器
│   └── windows-cli-pitfalls.md       # Windows CLI 陷阱
└── scripts/
    ├── regex-verify.js               # 正则验证工具
    └── run_cli.py                    # CLI 执行脚本
```

## 版本历史

- v12.5.0 (2026-07-30): MiMo CLI 状态更新（已验证 `xiaomi/mimo-v2.5`），Windows PATH 坑，MiMo 超时分拆执行技巧，Step 3 用户可指定 MiMo Code
- v12.4.0 (2026-07-30): 添加 Kimi CLI 作为 Step 4 替代，长 prompt 传递技巧
- v12.3.1 (2026-07-29): 修复循环绕过漏洞 — 自迭代例外仅限流程违规修复
- v12.3.0 (2026-07-29): 超时/失败硬化 — 结果验证门、失败分类矩阵、熔断器、工具白名单、终端状态
- v12.2.0 (2026-07-28): Step 3 CLI 声明要求，所有4步执行审计项
- v12.1.0 (2026-07-28): Windows 原生 Codex CLI EFTYPE 错误章节
- v12.0.0 (2026-07-28): 禁止中途汇报中断循环规则
- v10.0.0 (2026-07-27): Step 4 回归 MiMo Code
- v9.0.0 (2026-07-27): Step 3 切换到 Codex CLI
- v7.0.0 (2026-07-27): MiMo CLI 语法要点，--ephemeral 只读保障
- v6.0.0 (2026-07-27): Post-Completion Self-Audit + Loops 禁止直接 patch
- v2.1.0 (2026-07-22): 添加插件强制执行系统
- v2.0.0 (2026-07-22): 整合两个仓库，使用 Kimi CLI/MiMo Code/Codex CLI
- v1.0.0 (2026-07-21): 初始版本
