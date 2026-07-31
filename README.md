# 4步法强制执行系统 (Harness 4-Step Method)

> **v12.9.0** — Self-Audit Gate + Skill Name Conflict Fix + Kimi CLI Binding

## 系统组成

| 组件 | 作用 |
|------|------|
| SKILL.md | 定义4步法规则和流程（v12.9.0） |
| plugin/ | four-step-enforcer 技术强制执行插件 |
| references/ | 参考文档（CLI 语法、故障诊断、会话取证） |
| scripts/ | 工具脚本 |

## 4步法流程

| 步骤 | Agent（固定绑定） | Real CLI | 超时 | 限制 |
|------|-----------------|----------|------|------|
| Step 1 | **Codex CLI**（不可更改） | `codex exec` | 120s | 不能改代码 |
| Step 2 | **Kimi CLI**（不可更改） | `kimi -p` | 120s | 只出方案，不能改代码 |
| Step 3 | **Codex CLI**（不可更改） | `codex exec -s danger-full-access` | 120s | 按方案执行修改，不能做方案/审查 |
| Step 4 | **Kimi CLI**（不可更改） | `kimi -p` | 180s | 复审，不能改代码 |

**核心原则：每步 CLI 绑定后不可更改。** 用户设定后，该步的 CLI 工具永久固定，超时只重试不降级，不自动匹配历史使用过的其他 CLI。

**循环机制**：Step 4 发现问题 → 回到 Step 2 → Step 3 → Step 4，最多 10 轮。

## 快速开始

### 1. 安装技能

```bash
# 将 SKILL.md 及关联文件复制到 Hermes skills 目录
cp -r harness-4step ~/.hermes/skills/
```

### 2. 安装插件（可选，技术强制执行）

```bash
# 复制插件到正确位置
cp -r plugin/four-step-enforcer ~/.hermes/plugins/
```

### 3. 使用

在 Hermes 对话中加载技能：

```
/skill harness-4step
```

## 版本历史

- v12.9.0 (2026-07-31): 强化 self-audit 门禁，harness-4step-repo 移出 skills/ 解决技能名冲突，新增 BLOCKED_SKILL_LOAD_FAILURE
- v12.8.0 (2026-07-31): 添加 Kimi CLI Windows `.cmd` 包装器陷阱
- v12.7.0 (2026-07-31): 重大 CLI 绑定变更：Step 2 和 Step 4 统一使用 Kimi CLI，彻底移除 MiMo Code
- v12.6.0 (2026-07-30): 每步 CLI 绑定不可更改，超时只重试不降级，禁止自动匹配历史
- v12.5.0 (2026-07-30): MiMo CLI 语法要点、Windows PATH 坑、超时缓解技巧
- v12.4.0 (2026-07-30): 添加 Kimi CLI 作为 Step 4 选项
- v12.3.0 (2026-07-29): Result Verification Gate, Failure Classification Matrix, Circuit Breaker, Terminal Statuses
- v12.2.0 (2026-07-28): Step 3 CLI 声明要求，自审查清单
- v12.1.0 (2026-07-28): Windows 原生 Codex CLI EFTYPE 错误章节

## 许可证

MIT
