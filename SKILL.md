---
name: harness-4step
description: "Harness the 4-step method: Codex CLI Review -> Codex CLI Plan -> Codex CLI Execute -> MiMo Code Re-review"
version: 12.2.2
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [enforcement, workflow, rules, compliance, timeout]
    related_skills: [writing-plans, subagent-driven-development]
---

# Harness 4-Step Method (v12.2.2 — Naming Correction + Cross-Contamination Prevention)

## Naming Rules (IMPORTANT)
- **Official skill name: `harness-4step`** — there is NO skill named `enforce-4-step-method`; this was a historical misnomer fully removed on 2026-07-29.
- All references in skill metadata, docs, memory, and other skills MUST use `harness-4step`. Never use the old name.
- The 4-step method rules belong ONLY in this skill. Do NOT copy/paste 4-step rules, Step descriptions, MiMo/Codex CLI instructions, or Post-Completion Self-Audit templates into other skills (e.g. credential-pool-sync, bill-manager, etc.) — cross-contamination causes drift and confusion. Reference this skill instead.

### 技能重命名后清理清单（Pitfall）

当一个技能被重命名（如 `enforce-4-step-method` → `harness-4step`），清理时必须覆盖以下所有位置，否则旧名称会持续产生混淆：

1. **本地技能目录**：
   - SKILL.md frontmatter 的 `name:` 字段
   - SKILL.md 正文中的自我引用（如"更新 xxx skill 的对应章节"）
   - `.usage.json` 中的旧名称统计记录（删除或合并到新名称）
   - `.archive/` 下的旧版本归档目录（决定保留还是删除）

2. **Obsidian 备份**：
   - 项目控制台文档中的本地路径和仓库地址
   - 历史记录文档中的旧名称引用（区分"当前有效引用"和"历史归档上下文"）
   - 表格、目录树、列表中的名称

3. **其他技能和文档中的引用**：
   - 全局搜索旧名称，确认没有其他技能错误引用
   - 特别注意：related_skills 字段、skill_view 调用、记忆条目

4. **交叉污染检查**：
   - 检查其他技能中是否不小心写入了本技能的内容（例如凭证池技能中混入了四步法复审记录）
   - 这类内容必须删除，不能留在不相关的技能里

**处理原则**：
- **当前有效引用**（路径、名称、配置）→ 必须全部替换为新名称
- **历史归档上下文**（整合记录、迁移说明、版本历史）→ 可以保留旧名称，但必须添加"旧名称，已归档/已重命名"的明确注释，避免读者误以为仍在使用

## Overview

Harnesses the 4-step method with real CLI execution. v12 adds: naming standardization, cross-contamination prevention rules, timeout resilience per CLI tool, fallback paths when a CLI fails, and subagent constraint injection for delegate_task.

## Core Principle

**Role label != Execution.** Real CLI execution requires calling the actual tool binary — codex exec, mimo run, or kimi -p. No delegating the task to a subagent and calling that "CLI execution." This skill harnesses the structured workflow to prevent process violations.

## The 4-Step Method

**MANDATORY for all code changes:**

| Step | Agent | Real CLI | Timeout | Fallback | 限制 |
|------|-------|----------|---------|----------|------|
| Step 1 | **Codex CLI** | codex exec | 120s | 精简提示重试，加 tail -60 | 不能改代码 |
| Step 2 | **Codex CLI** | codex exec (read-only) | 120s | 同上 | **不能改代码**，必须用 --ephemeral + 输出方案不改文件 |
| Step 3 | **Codex CLI** | codex exec -s danger-full-access | 120s | 写 prompt 文件再 exec / 分段执行 | 不能做方案/审查 |
| Step 4 | **MiMo Code CLI** | mimo run | 180s | Codex CLI 短英文提示 | 不能改代码 |

## Windows 原生 Codex CLI EFTYPE 错误（本地执行失败）

**问题**：在 Windows 本机运行 `codex exec` 时报 `Error: spawn EFTYPE (errno: -4028)`。错误在 `codex.js:195` 的 `spawn()` 调用处抛出。

**根因**：`codex.js` 调用 `findCodexExecutable()` 找到平台相关包 `@openai/codex-win32-x64` 下的 `codex.exe`，但该二进制文件已损坏/不完整——Windows 不识别为有效可执行映像。

**与其他 Codex 失败的区别**：

| 症状 | 原因 | 处理 |
|------|------|------|
| `spawn EFTYPE` | `codex.exe` 二进制损坏 | 重装 Codex CLI |
| 超时 (exit 124) | 网络/模型响应慢 | 精简 prompt 重试 |
| `Missing optional dependency` | win32-x64 包未安装 | 重装 Codex CLI |
| `Command not found` | PATH 未配置 | 检查 npm 全局安装路径 |

**诊断步骤**：

```bash
# 1. 确认 Codex 已安装
npm list -g @openai/codex

# 2. 检查 win32-x64 包是否存在
node -e "try{require.resolve('@openai/codex-win32-x64/package.json');console.log('OK')}catch(e){console.log('MISSING:',e.message)}"

# 3. 检查 codex.exe 是否存在
node -e "const p=require('path'),f=require('fs');const d=p.join(p.dirname(require.resolve('@openai/codex-win32-x64/package.json')),'vendor','x86_64-pc-windows-msvc','bin','codex.exe');console.log('exists?',f.existsSync(d));if(f.existsSync(d))console.log('size:',f.statSync(d).size,'bytes')"

# 4. 尝试直接运行二进制（如果 EFTYPE 则确认损坏）
node -e "const p=require('path'),f=require('fs');const d=p.join(p.dirname(require.resolve('@openai/codex-win32-x64/package.json')),'vendor','x86_64-pc-windows-msvc','bin','codex.exe');console.log('path:',d)"
```

**修复**：重新安装 Codex CLI

```bash
npm uninstall -g @openai/codex
npm install -g @openai/codex
```

重装后验证：
```bash
codex --version
# 应输出 v0.xxx.x，不报 EFTYPE
```

**坑**：
- `codex exec` 直接通过 npm 全局安装的 `codex.cmd` 调用，不要混用 Trae/IDE 自带版本
- EFTYPE 不是 shell wrapper 问题——用 `node` 直接调用 `codex.js` 也会报同样错误
- 之前的记忆 "Codex EFTYPE→用node绕过shell wrapper" 针对的是不同的 EFTYPE 场景（shell 脚本转义），对 `spawn()` 本身的 EFTYPE 无效

## SSH 到 Windows 远程执行 Codex CLI 的 PowerShell 转义陷阱

**问题**：通过 `ssh 10.0.0.50 "cd /d C:\\path && codex exec ..."` 远程执行 Codex CLI 时，目标机器的默认 shell 是 **PowerShell**，不是 cmd.exe。PowerShell 对以下字符有特殊含义：

| 字符 | PowerShell 行为 | 实际效果 |
|------|----------------|----------|
| `&&` | 无效运算符 → ParserError | 命令不执行 |
| `&` | 调用运算符 → 需要 `& command` | 路径被解释为命令 |
| `--flag` | 长参数被截断 | `--skip-git-repo-check` → `-git-repo-check` 找不到命令 |
| `\` | 路径分隔符被 MSYS bash 消耗 | `C:\Users\...` → `C:Users...` |

**症状**：SSH 命令返回 `'&&' 不是此版本中的有效语句运算符` 或 `'-git-repo-check' 不是内部或外部命令`。

**可靠的工作流（按优先级）**：

### 方案 A：本地 Codex 执行（首选）
Codex CLI 在 87 本机也可用。直接在本机运行 codex exec，完全绕开 SSH 转义问题：
```bash
cd /c/Users/Administrator/ecommerce-assistant/bill-manager
codex exec -m gpt-5.6-luna --dangerously-bypass-approvals-and-sandbox --ephemeral "简短审查" 2>&1 | tail -60
```
**何时用**：代码在 87 和 50 之间通过 Git 同步（同一分支），或远程代码变更可通过 git pull 拉取。

### 方案 B：本地写 .bat 文件 → SCP 到远程 → SSH 执行
当必须操作 50 上的本地文件（如未推送的变更）时：
```bash
# 1. 写 batch 文件（本地）
cat > /tmp/codex_step1.bat << 'BATEOF'
@echo off
cd /d C:\Users\Administrator\ecommerce-assistant\bill-manager
codex exec -m gpt-5.6-luna --dangerously-bypass-approvals-and-sandbox --ephemeral "简短审查" 2>&1
BATEOF

# 2. SCP 到远程
scp /tmp/codex_step1.bat 10.0.0.50:"C:\\Users\\Administrator\\codex_step1.bat"

# 3. SSH 执行
ssh 10.0.0.50 "C:\\Users\\Administrator\\codex_step1.bat"
```
**坑**：SCP 后文件路径中的中文可能乱码，保持 prompt 简洁或用英文。

### 方案 C：cmd.exe /c 显式指定（备选）
```bash
ssh 10.0.0.50 cmd.exe '/c cd /d C:\path & codex exec ...' 2>&1
```
用 `&` 替代 `&&`（cmd.exe 支持 `&`），但需确保整个命令字符串不被 MSYS bash 和 PowerShell 双重解析。路径中的反斜杠要小心。

### 降级记录
使用方案 B 或 C 时，在汇报中注明：
```
CLI execution: SSH to 10.0.0.50 (PowerShell转义降级 → 本地batch文件方案)
```

## CLI Timeout Handling

### 通用规则
1. 第一次超时 -> 精简 prompt 重试一次
2. 第二次超时 -> 执行降级路径
3. 在汇报中注明超时和降级

### Step 1/2: Codex CLI 超时
精简版避免超时：
  codex exec -m gpt-5.6-luna --dangerously-bypass-approvals-and-sandbox --ephemeral "简短审查" 2>&1 | tail -60

**Step 2 技术只读保障：** 必须使用 `--ephemeral` 标志（沙箱环境，不保留工作区改动）。执行后必须验证 `git status` 无变化；若有改动则 Step 2 失败，不可静默保留。

- 不要用 delegate_task 冒充 Codex
- 不要手工写审查报告
- Step 2 输出方案文字，不调用 apply/edit 工具

### MiMo CLI 语法要点（Windows 环境已验证）

> ✅ 当前状态：MiMo Code CLI 已登录可用。Provider: MiMo, User ID: 2268282840，使用 `xiaomi/mimo-v2.5` 模型。`mimo providers login` → 选 MiMo (推荐) → 浏览器认证 → 粘贴 code 完成登录。

**基本语法**：

**基本语法**：
```bash
mimo run --model <provider/model> <message>
```
- `message` 是 **positional argument**（位置参数），直接在选项后输入即可
- `--command` 是用于 predefined 命令（`init`, `review`, `dream`, `goal` 等），不能用于自由消息

**模型命名规则**：`provider/model` 格式，如 `anthropic/claude-sonnet-4-5`

**可用模型列表**：`mimo models` 列出所有可用模型

**认证管理**：
```bash
mimo providers list      # 列出已配置的 credentials
mimo providers whoami    # 显示当前登录状态
mimo providers login     # 登录 MiMo 服务
mimo providers logout    # 退出登录
```

**API Key 有效性验证**（绕过 mimo 直接测试）：
```bash
curl -s -w "%{http_code}" https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-sonnet-4-20250514","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
```
- 401 = key 无效/过期
- 200/201 = key 正常

**不登录的限制**：
- `mimo/mimo-auto` → 需要登录 MiMo 服务
- `xiaomi/mimo-v2.5` / `xiaomi/mimo-v2.5-pro` → 需要登录 MiMo 服务
- `anthropic/claude-*` → 需要有效 `ANTHROPIC_API_KEY` 环境变量

### Step 3: Codex CLI 超时
降级路径：
  方案1: 写 prompt 文件再 exec
  方案2: 分段 codex exec

- 降级后仍需要验证结果
- 降级不是跳过步骤，而是换工具完成同一件事

### Step 4: MiMo Code 超时
**降级路径（按顺序）：**
1. 短英文提示 + timeout 180s 重试一次
2. 仍失败 → **直接降级到 Codex CLI 复审**（短英文提示）
3. Codex CLI 也不可用 → 才允许人工验证

**降级必须记录：** 在汇报中注明「MiMo Code 超时 → Codex CLI 降级」。

- 强制用英文简短提示

### 降级路径必须声明
CLI 失败后（包括认证错误、HTTP 403），必须先明确声明降级路径才能继续：
1. 重试同一 CLI → 说明重试原因
2. 降级到指定替代 CLI → 说明哪个 CLI + 只读控制
3. 请求用户批准手动提交 → 必须先说明失败原因和降级理由

未声明降级路径的手动提交属于违规。

### Step 3 入口门禁
在任何 Step 3 命令、编辑或委托之前，**必须先在用户可见消息中声明**：
```
Step 3 implementation CLI: <工具和模式>
```
不使用 CLI 时声明：
```
Step 3 implementation CLI: none — <原因和批准的替代方案>
```
第一个 Step 3 操作之前未出现此声明，则 Step 3 视为未启动。事后声明不纠正违规。

### 自我审查修正例外声明
应用任何自我审查 patch 之前，必须声明：
```
Self-audit correction exception: <发现的问题>; files in scope: <文件范围>; verification: <验证方式>
```
声明前不得进行任何纠正编辑。超出声明文件范围的修正需要新声明。

### delegate_task 约束注入
当使用 delegate_task 时，必须在 context 字段追加以下约束：

## 4步法约束（必须遵守）
1. 必须使用真实 CLI 工具（codex exec / mimo run / kimi -p），不能模拟
2. Step 2 只出方案不修改代码
3. 不能手工创建 evidence.json
4. 不能在 goal 字段标注角色但不调用对应 CLI
5. 汇报中注明：使用的 CLI 命令、退出码、输出摘要

### 禁止行为（子 Agent 同样适用）
- 用 delegate_task 返回文本冒充 CLI 输出
- 手工创建 evidence.json
- 仅检查 subprocess 启动成功
- CLI 失败后继续推进步骤
- 在 goal 字段标注角色但不调用对应 CLI

### four-step-enforcer 插件
插件会拦截 write_file/patch/skill_manage 操作。允许的绕过方式：
- terminal -> 用 Python 脚本或 shell 命令修改配置文件
- 限制：仅用于配置文件（config.yaml、auth.json），不用于代码文件
- 不能删除或禁用插件本身

## 汇报模板

## Step X 执行汇报

| 项目 | 内容 |
|------|------|
| 当前步骤 | Step X |
| CLI调用 | codex exec ... |
| 退出码 | 0 / 124(超时) |
| 超时降级 | 是/否 -> [降级路径] |
### Post-Completion Self-Audit（末尾审查）

**每次 4 步法结束后，必须立即执行自我审查，不可跳过。**

### 审查清单

检查以下违规项，每项回答「是/否」：

1. **Step 4 发现问题后是否直接 patch 绕过循环？** → 必须回到 Step 2→3→4，不能直接用 patch/write_file 修复
2. **Step 3 是否使用了正确的 CLI？** → Codex CLI -s danger-full-access
3. **Step 1/2 是否用了 Codex CLI？** → 不能用 read_file 自己审查代替
4. **所有步骤是否都调用了真实 CLI？** → 不能用 Hermes 工具（patch/write_file/terminal）代替
5. **Codex 超时/转义失败后是否走了降级路径？** → 精简提示重试 / 写 prompt 文件再 exec
6. **Step 4 复审后是否有未处理的警告？** → Step 4 指出的问题必须进入循环
7. **是否跳过了 Step 2 或 Step 4？** → 必须完整执行 4 个步骤
8. **是否在 Step 3 前声明了 CLI？** → 必须先声明 "Step 3 implementation CLI: <工具和模式>"

### 触发自我迭代

如有任意一项为「是」（违规），必须：

1. 记录违规详情（在最终回复中列出违规清单）
2. 用 `skill_manage(action='patch')` 更新 harness-4step skill 的对应章节
3. 版本号 +1
4. 在最终回复中向用户说明已修复的违规

### 末尾审查声明（必须在最终回复中）

每次 4 步法结束时，在总结中必须添加：

| Post-Completion Self-Audit | Result | Evidence |
|---|---|---|
| Step 2 was technically read-only | Pass/Fail/N/A | Flag, mode, or isolation used |
| Step 2 left the workspace unchanged | Pass/Fail/N/A | Verification performed |
| Step 3 CLI was declared before action | Pass/Fail/N/A | Declared tool and mode |
| CLI failure followed an explicit downgrade path | Pass/Fail/N/A | Path taken |
| Self-audit patches were pre-declared | Pass/Fail/N/A | Exception declaration |
| Required verification completed | Pass/Fail/N/A | Checks and results |
| All 4 steps were executed | Pass/Fail/N/A | Step sequence completed |
| Step 3 CLI declaration present | Pass/Fail/N/A | Declaration found |

有 Fail 项必须自我迭代 skill，不能跳过。每行都必须存在，不适用的用 `N/A — 原因`。

### skill 自迭代例外

skill 文件（SKILL.md）的更新属于流程/规则变更，不走四步法——直接用 `skill_manage(action='patch')` 修改。原因：
1. skill 是元数据/流程规范，不是功能代码
2. four-step-enforcer 插件会拦截 skill_manage 但允许手动绕过用于自迭代
3. 自迭代内容直接来自本次执行的违规，不需要单独审查

## Loops Mechanism

When Step 4 fails, the process loops back to Step 2:

Step 1 -> Step 2 -> Step 3 -> Step 4
                ^               |
                |    FAIL       |
                +---------------+

Maximum Loops: 10

### 循环中禁止的行为
- 禁止用 patch/write_file 直接修复 → 必须走完 Step 2→3→4
- 禁止跳过任一 CLI 步骤
- 禁止修改非本次循环目标的其他代码

### 禁止中途汇报中断循环（v12.2.1 新增）
Step 3 完成后必须立即进入 Step 4，**不得以"达到工具调用上限"或"需要用户确认"为由停下来汇报**。四步法是一个原子流程：
- Step 3 → Step 4 之间不允许有面向用户的中间汇报
- 即便工具调用轮次耗尽，下一轮的第一件事必须是继续 Step 4
- 违反此规则的"Step 3 完成"汇报等同于跳过 Step 4，按违规处理
- 唯一允许中断的情况：所有 CLI 工具都不可用且已穷尽降级路径

## Version History
- v12.2.2 (2026-07-29): Fixed long-standing naming error — skill correctly named `harness-4step` everywhere; added Naming Rules section and cross-contamination prevention rule (4-step content must live only in this skill, never copied into other skills like credential-pool-sync); removed all references to old `enforce-4-step-method` name.
- v12.2.1 (2026-07-28): Added "禁止中途汇报中断循环" rule — Step 3 完成后必须立即进入 Step 4，不得以工具调用上限为由停下来汇报。违反等同跳过 Step 4。
- v12.1.0 (2026-07-28): Added Windows native Codex CLI EFTYPE error section
- v12.2.0 (2026-07-28): Added **Step 3 CLI declaration requirement** and **All 4 steps executed** audit item — to prevent skipping Step 2 or Step 4
- v10.1.0 (2026-07-27): Added `references/mimo-cli-login.md` with full login flow (free + OAuth), known issues, and credential storage details; added pointer in MiMo CLI section
- v10.0.0 (2026-07-27): Step 4 reverted back from Codex CLI to MiMo Code; fixed Step 4 section header; clarified MiMo 不可用走降级路径
- v9.0.0 (2026-07-27): Step 3 switched from MiMo Code to Codex CLI (Step 4 also switched but later reverted in v10.0.0)
- v7.1.0 (2026-07-27): Added MiMo CLI 语法要点 section: correct `mimo run` syntax, positional args vs --command, provider management commands, API key validation, and login requirements
- v7.0.0 (2026-07-27): Step 2 --ephemeral只读保障 + Step 3入口门禁 + 降级路径必须声明 + 自我审查修正例外声明 + 固定末尾审查表格
- v6.0.0 (2026-07-27): Step 4 Kimi额度用尽降级到Codex CLI + 末尾审查声明必须展示 + 违规记录必须列出 + skill自迭代例外规则
- v5.0.0 (2026-07-27): Added Post-Completion Self-Audit + Loops禁止直接patch + Step 3 支持 Codex CLI (MiMo 不可用时的降级)
- v4.0.0 (2026-07-26): CLI timeout handling per tool, MiMo/Kimi fallback paths, subagent constraint injection, removed run_cli.py dependency
- v3.0.0 (2026-07-24): Real CLI execution via direct tool calls
- v2.2.0 (2026-07-22): Updated step1/2 to Codex CLI, step4 to Kimi CLI K3
- v2.1.0 (2026-07-22): Added plugin enforcement system
- v2.0.0 (2026-07-22): Updated to use Kimi CLI/MiMo Code/Codex CLI
- v1.0.0 (2026-07-21): Initial version with Loops mechanism
