---
name: harness-4step
description: "Harness the 4-step method: Codex CLI Review -> Codex CLI Plan -> Codex CLI Execute -> Kimi CLI Re-review (绑定固定，不自动降级)"
version: 12.15.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [enforcement, workflow, rules, compliance, timeout, cli-binding]
    related_skills: [writing-plans, subagent-driven-development]
---

# Harness 4-Step Method (v12.15.0 — Process Integrity + Multi-Loop Queue)

## Naming Rules (IMPORTANT)
- **Official skill name: `harness-4step`** — there is NO skill named `enforce-4-step-method`; this was a historical misnomer fully removed on 2026-07-29.
- All references in skill metadata, docs, memory, and other skills MUST use `harness-4step`. Never use the old name.
- The 4-step method rules belong ONLY in this skill. Do NOT copy/paste 4-step rules, Step descriptions, Codex/Kimi CLI instructions, or Post-Completion Self-Audit templates into other skills (e.g. credential-pool-sync, bill-manager, etc.) — cross-contamination causes drift and confusion. Reference this skill instead.

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

Harnesses the 4-step method with real CLI execution. v12.3.0 adds: result verification gates after every CLI call, failure classification matrix, circuit breaker for repeated identical failures, tools-in-scope allowlist, pre/post state capture around Step 3, terminal statuses, enhanced reporting template, and enhanced self-audit. See `references/session-forensics.md` for diagnosing 4-step execution faults.

## Core Principle

**Role label != Execution.** Real CLI execution requires calling the actual tool binary — codex exec or kimi -p. No delegating the task to a subagent and calling that "CLI execution." This skill harnesses the structured workflow to prevent process violations.

## The 4-Step Method

**MANDATORY for all code changes.**

**核心原则：每步 CLI 绑定后不可更改。** 用户设定后，该步的 CLI 工具永久固定，超时只重试不降级，不自动匹配历史使用过的其他 CLI。

| Step | Agent（固定绑定） | Real CLI | Timeout | 超时策略 | 限制 |
|------|-----------------|----------|---------|---------|------|
| Step 1 | **Codex CLI**（不可更改） | codex exec --ephemeral | 120s | 精简 prompt 重试，仍超时则继续精简重试，不换工具 | 不能改代码，只审查 |
| Step 2 | **Codex CLI**（不可更改） | codex exec --ephemeral | 120s | 同上 | **不能改代码**，只输出方案不改文件 |
| Step 3 | **Codex CLI**（不可更改） | codex exec -s danger-full-access | 120s | 写 prompt 文件再 exec / 分段执行，不换工具 | 不能做方案/审查 |
| Step 4 | **Kimi CLI**（不可更改） | kimi -p | 180s | 精简 prompt 重试，仍超时则继续精简重试，不换工具，不降级 | 不能改代码 |

**绑定规则：**
- Step 1、Step 2、Step 3 的 CLI 是 **Codex CLI**，Step 4 的 CLI 是 **Kimi CLI**，一旦指定，**不得自动匹配历史使用记录**
- 不得在超时后擅自降级到其他 CLI
- 如需更改 CLI，必须用户明确重新指定

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
| `\\` | 路径分隔符被 MSYS bash 消耗 | `C:\\Users\\...` → `C:Users...` |

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

### Windows npm CLI PATH 问题
在 Windows MSYS bash 环境中，codex 和 kimi 都是 `.cmd` 批处理包装器，位于 `%AppData%/npm/`。新 shell 会话可能不包含该目录在 PATH 中。每次调用前必须显式导出：

```bash
export PATH="$PATH:/c/Users/<username>/AppData/Roaming/npm"
```

如果 `codex --version` 或 `kimi --version` 返回 `command not found`，说明 PATH 未配置。以上命令修正后即可使用。

### 通用规则
1. 第一次超时 -> 精简 prompt 重试一次
2. 第二次超时 -> 继续精简 prompt 重试，**不降级到其他工具**
3. 在汇报中注明超时和重试情况
4. **关键约束**：当用户明确指定某步的 CLI 工具（如 Step 4 用 Kimi CLI），**永远不降级到其他工具**

### 超时处理优先级
1. **用户指定工具优先**：用户明确指定的 CLI 必须一直尝试，直至工具完全不可用（如命令找不到、EFTYPE）
2. **精简提示为重**：每次超时后，必须精简提示内容再重试，不得直接放弃
3. **如实报告状态**：当工具完全不可用时（如 Kimi CLI 完全无法启动），报告工具不可用阻塞，**不视为流程违规**
4. **不可自动匹配**：不得自动匹配历史中使用过的其他 CLI

### Kimi CLI 语法要点（Windows 环境已验证）

> ✅ 当前状态：Kimi CLI v0.28.0 可用。

**基本语法**：
```bash
kimi -p "<prompt>"
```
- `-p` / `--prompt` 接受一个 **positional argument**（字符串参数），不是 stdin
- 长 prompt 不能通过管道传入，需要写 .bat 文件或用 Python subprocess

**长 prompt 传递方式（Windows MSYS bash）：**

方案 A：写 .bat 文件执行
```bash
# 写 batch 文件
cat > /tmp/kimi_step4.bat << 'BATEOF'
@echo off
cd /d C:\path\to\project
kimi -p "简短审查" 2>&1
BATEOF

# 执行
cmd.exe /c "C:\path\to\temp\kimi_step4.bat"
```

方案 B：Python subprocess（推荐，支持长 prompt 无转义问题）
```python
import subprocess
prompt = "Review the 4 changes..."
r = subprocess.run(['kimi', '-p', prompt], capture_output=True, text=True, timeout=120,
                   encoding='utf-8', errors='replace')
print(r.stdout)
```

**坑**：
- `kimi -p` 不接受 stdin 管道，`cat prompt.md | kimi -p` 会报 `argument missing`
- 通过 MSYS bash 的 cmd.exe /c 调用时，中文引号嵌套可能导致解析错误
- Kimi 的超时行为：180s 超时后命令被强制终止，但部分输出可能已写入 stdout
- `kimi --version` 验证安装：v0.28.0 可用
- Kimi CLI 没有 `--ephemeral` 或 `--skip-git-repo-check` 等标志，只读审查时需自行确保不修改文件
- **Windows 上 kimi 是 `.cmd` 批处理包装器**：Python `subprocess.run(['kimi', '-p', prompt])` 会报 `FileNotFoundError`，因为 `.cmd` 文件不是可执行映像。必须用 `shell=True` 或传完整路径 `kimi.cmd`。示例：
  ```python
  import subprocess
  r = subprocess.run(['kimi.cmd', '-p', prompt], capture_output=True, text=True,
                     timeout=180, encoding='utf-8', errors='replace', shell=True)
  ```
### Step 2: Codex CLI 超时 — 备用方案

当 Step 2 的 Codex CLI --ephemeral 在代码分析类 prompt 下连续超时（exit 124），且 Step 1 审查已给出具体修复建议时，可以直接基于 Step 1 审查输出中的修复建议作为方案，进入 Step 3 执行。规则：

1. **仅限连续超时**：必须至少重试 2 次精简 prompt 后仍超时，才启用此备用方案
2. **Step 1 审查必须包含具体修复建议**：方案必须来自 Step 1 Codex 审查输出的精确代码片段或修改建议，不得自行编造
3. **声明要求**：在 Step 3 声明中注明"Step 2 方案基于 Step 1 Codex 审查输出（Codex CLI 连续超时）"
4. **Step 4 仍需 Kimi CLI**：复审步骤仍必须用 Kimi CLI，不得以此为由跳过 Step 4

This is a timeout workaround, not a tool downgrade — the plan source falls back to Step 1 output, but Step 4 still requires Kimi CLI.

### Step 4: Kimi CLI 超时

**当用户已明确配置 Step 4 使用 Kimi CLI：**
1. 第一次超时 -> 精简 prompt 重试一次（timeout 保持 180s）
2. 第二次超时 -> 再次精简 prompt 重试，**不得擅自降级到其他工具**
3. 仍超时 -> 如实报告工具状态：「Kimi CLI 已超时 2 次，无法完成 Step 4 复审」
4. **用户约束**：如果用户明确说了「不能降级」，则停止所有降级尝试，如实报告阻塞

**禁止行为：**
- ❌ 自动切换到历史中使用过的其他 CLI
- ❌ 超时后未经用户同意直接降级到 Codex CLI
- ❌ 以「提高成功率」为由忽略用户指定的 CLI
- ❌ 声称「Step 4 完成」但实际用了未授权的工具

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

### Step 3 执行方法约束（v12.3.2 新增）
Step 3 的修改**默认通过 Codex CLI -s danger-full-access 执行**。禁止以下行为：
- ❌ 用 bash/terminal 直接调用 `patch`、`write_file` 来修改代码
- ❌ 用 `delegate_task` 返回文本冒充 CLI 执行结果
- ❌ 用 `skill_manage(action='patch')` 绕过循环（自迭代例外仅限流程违规修复）

正确做法：将修改方案写入 prompt 文件，通过管道传给 Codex CLI 执行：
```
cat prompt.md | codex exec -m gpt-5.6-luna --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check
```

例外：配置文件（config.yaml、auth.json）的修改可以通过 harness-4step 插件的 bypass 机制用 terminal 处理，但必须在声明中注明。

### 自我审查修正例外声明
应用任何自我审查 patch 之前，必须声明：
```
Self-audit correction exception: <发现的问题>; files in scope: <文件范围>; verification: <验证方式>
```
声明前不得进行任何纠正编辑。超出声明文件范围的修正需要新声明。

### delegate_task 约束注入
当使用 delegate_task 时，必须在 context 字段追加以下约束：

## 4步法约束（必须遵守）
1. 必须使用真实 CLI 工具（codex exec / kimi -p），不能模拟
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

### harness-4step 插件
插件会拦截 write_file/patch/skill_manage 操作。允许的绕过方式：
- terminal -> 用 Python 脚本或 shell 命令修改配置文件
- 限制：仅用于配置文件（config.yaml、auth.json），不用于代码文件
- 不能删除或禁用插件本身

## Result Verification Gate

### 强制规则：每条 CLI 调用后必须验证

**每次 CLI 调用（包括重试和降级）后，必须执行以下验证：**

1. **输出存在性检查**：CLI 是否产生了 stdout 输出？空输出（无论退出码）视为失败，不得声称成功。
2. **输出相关性检查**：输出是否包含与当前步骤目标相关的内容？（例如 Step 2 的方案是否包含具体修复点）。
3. **退出码检查**：exit 124（超时）无论是否有部分输出，都视为失败，不得声称完成。
4. **验证门**：
   - Step 1/2：确认输出包含审查发现或方案要点
   - Step 3：确认 diff 或代码修改已实际写入文件
   - Step 4：确认复审结论包含具体问题或确认

**验证失败的处理**：
- 验证未通过，不能在汇报中声称该步骤"完成"
- 必须记录验证失败的具体原因
- 验证失败等同于 CLI 失败，走降级/重试路径

### 防虚假成功规则

**不得在以下情况声称步骤完成：**
- CLI 返回 exit 124（超时），无论输出是否部分存在
- CLI 返回空 stdout（即便 exit code 是 0）
- CLI 输出只有帮助信息、错误信息或无关内容
- 降级路径未执行（仅声明了降级但未实际调用替代 CLI）

**正确做法：**
```
// 错误 ❌
Step 2 complete ✅（11 点修复方案）

// 正确 ✅
Step 2: Codex CLI timed out (exit 124, empty output)
→ 精简 prompt 重试
→ 第二次仍超时
→ 降级到本地验证
```

## Failure Classification Matrix

| 失败类型 | 判断依据 | 是否可重试 | 是否可降级 | 是否终止流程 |
|---------|---------|-----------|-----------|------------|
| **超时** | exit 124 或 timeout 异常 | 是（精简 prompt 重试，次数不限） | 否（**禁止降级到其他工具**） | 否（除非工具完全不可用） |
| **空输出** | exit 0 但 stdout 为空 | 是（重试，次数不限） | 否 | 否（除非工具完全不可用） |
| **认证失败** | HTTP 401/403、auth error | 是（重新认证后重试） | 否（用户指定的工具必须坚持用） | 如果用户明确不可降级则终止 |
| **可执行文件失败** | EFTYPE、command not found、Missing dependency | 是（修复后重试） | 否 | 是（工具完全不可用则终止） |
| **无效输出** | 输出存在但内容不相关（如帮助信息、错误日志） | 是（精简 prompt 重试，次数不限） | 否 | 否（除非工具完全不可用） |

**重试规则：**
- 用户指定的 CLI 工具，**不限次数重试**，直至工具完全不可用
- 每次重试必须精简提示内容
- 不得在任何情况下自动切换到未指定的 CLI

**跨步骤失败累计：** 如果累计 3 个步骤的同一指定 CLI 都超时，如实报告整体阻塞，**不视为流程违规**

## Circuit Breaker

### 单 CLI 熔断
当同一步骤的同一 CLI 连续 2 次发生**相同的失败类型**（都是超时，或都是空输出），则打开该 CLI 的 circuit breaker：
- 不再重试该 CLI 命令
- 必须切换到降级路径（不同 CLI 或不同执行方式）
- 如果降级路径也失败，则打开步骤级熔断

### 步骤级熔断
当某步骤的 CLI 和降级路径都失败，该步骤打开 circuit breaker：
- 该步骤标记为 BLOCKED
- 不能继续执行后续步骤
- 整体流程以 `BLOCKED_CLI_FAILURE` 终止

### 全局熔断（v12.3.0 新增）
当连续 3 个步骤（不限顺序）都因超时/空输出/无效输出失败，打开全局熔断：
- 立即终止整个 4 步法流程
- 终端状态为 `BLOCKED_CLI_FAILURE`
- 不得继续任何步骤，不得声称部分完成
- 必须向用户报告失败原因和已执行步骤

## Tools-in-Scope Allowlist

### 每步骤允许的工具

| 步骤 | 允许的工具 | 禁止的工具 |
|------|-----------|-----------|
| Step 1 | terminal（运行 codex exec --ephemeral）、write_file（写 prompt 文件）、read_file（读代码） | patch、write_file（改代码）、memory、skill_manage、text_to_speech、delegate_task（代替 CLI） |
| Step 2 | terminal（运行 codex exec --ephemeral）、write_file（写 prompt 文件）、read_file（读代码） | patch、write_file（改代码）、memory、skill_manage、text_to_speech、delegate_task（代替 CLI） |
| Step 3 | terminal（运行 codex exec -s）、write_file（写 prompt 文件）、read_file | text_to_speech、delegate_task（代替 CLI）、memory、skill_manage（非自迭代）、patch（除非在 harness-4step 插件允许的绕过范围内，仅限 config.yaml/auth.json） |
| Step 4 | terminal（运行 kimi -p）、read_file | patch、write_file、text_to_speech、delegate_task（代替 CLI） |

### 全局禁止
- **text_to_speech**：在 4 步法流程的任何步骤中，禁止调用 text_to_speech 工具。该工具与步骤目标无关，调用它会生成无关文件和混淆。
- **delegate_task 冒充 CLI**：禁止用 delegate_task 返回文本冒充 CLI 输出。delegate_task 可用于辅助任务（如并行审查），但不能替代 Step 1/2/3/4 的 CLI 调用。
- **memory 写入**：在 4 步法流程中，禁止写入 memory（自迭代 skill 更新除外）。流程结束后才能记录。

## Terminal Statuses

每次 4 步法结束时，必须分配一个明确的终端状态：

| 状态 | 含义 | 条件 |
|------|------|------|
| **COMPLETED** | 所有步骤成功完成，验证通过 | 4 个步骤都按用户指定的 CLI 执行并验证通过，且 Post-Completion Self-Audit 已执行，自审查声明块已出现在最终回复末尾，Enhanced Self-Audit 所有适用项为 PASS |
| **BLOCKED_CLI_FAILURE** | CLI 工具不可用导致流程终止 | 指定的 CLI 完全不可用（如 EFTYPE、命令找不到），且无法修复 |
| **BLOCKED_SKILL_LOAD_FAILURE** | 技能文件加载失败导致流程终止 | 最新 SKILL.md 无法通过 skill_view 成功加载并验证 name/version |
| **FAILED_VERIFICATION** | 步骤执行了但验证未通过 | Step 3 修改后验证失败，或 Step 4 复审发现问题 |
| **FAILED_VERIFICATION** | 总审查发现遗漏、冲突或回归失败 | 总审查发现问题；如有可执行 loop，进入修复 loop |
| **BLOCKED_CLI_FAILURE** | 总审查 CLI 不可用 | 总审查期间 CLI 不可用或触发熔断 |
| **ABORTED_SCOPE_VIOLATION** | 超出范围或违规操作 | 修改了非目标代码，或跳过步骤，或使用禁止的工具 |
| **CANCELLED_BY_USER** | 用户主动取消流程 | 用户明确要求停止，所有步骤停止 |
| **BLOCKED_TIMEOUT_RETRY** | 多次超时但仍可重试 | 用户指定的 CLI 超时，但工具本身可用，等待后续重试 |

**关键例外：**
- 因 CLI 工具本身不可用（如 EFTYPE、command not found）导致的阻塞，**视为工具故障阻塞，不视为流程违规**
- 用户指定的 CLI 多次超时但工具本身可用时，应持续重试，**不得直接终止流程**

**终端状态不得为 COMPLETED 当：**
- 任何步骤使用了未授权的 CLI 工具
- 未按用户指定的 CLI 执行步骤
- 自动切换到了历史中使用过的其他 CLI
- 未执行 Post-Completion Self-Audit（审查清单 9 项 + Enhanced Self-Audit 14 行）
- 最终回复末尾缺少自审查声明块
- Enhanced Self-Audit 任一适用项为 FAIL（此时必须为 FAILED_VERIFICATION）

## Pre/Post State Capture

### Step 3 前状态基线

在 Step 3 执行前，必须捕获工作区基线：
- 当前工作目录
- 当前分支或等同的仓库标识
- `git status --short`
- `git diff --no-ext-diff`
- 相关的未跟踪文件状态
- 允许修改的预期文件列表

基线必须保留以便与执行后状态对比。

### Step 3 后状态验证

Step 3 完成后，必须捕获相应的执行后状态并与基线对比：

1. 变更仅限于授权的工作区和预期范围
2. 请求的实现变更已实际存在
3. 没有意外的破坏性变更或无关修改
4. CLI 输出与观察到的 diff 和工作区状态一致
5. CLI 报告的任何测试、检查或生成产物实际存在或可验证完成

如果 Step 3 超时或失败后可能已修改工作区，必须在重试或降级前捕获失败后状态。

**未捕获基线或执行后状态**，不得产生 COMPLETED 结果，必须产生 FAILED_VERIFICATION，除非不可捕获本身就是不可恢复的 CLI 失败。

## 汇报模板

### Enhanced Reporting Template

最终汇报必须使用以下结构：

```
Terminal status: <COMPLETED | BLOCKED_CLI_FAILURE | FAILED_VERIFICATION | ABORTED_SCOPE_VIOLATION>

Step 1: Codex CLI review
- Attempt: <number of attempts>
- CLI: <CLI name>
- Exit code: <code or timeout>
- Output present: <yes/no>
- Output relevance: <relevant/irrelevant/incomplete>
- Verification result: <passed/failed>
- Fallback reason: <none or specific reason>

Step 2: Codex CLI plan
- Attempt: <number of attempts>
- CLI: <CLI name>
- Exit code: <code or timeout>
- Output present: <yes/no>
- Output relevance: <relevant/irrelevant/incomplete>
- Verification result: <passed/failed>
- Fallback reason: <none or specific reason>

Step 3: Codex CLI execute
- Attempt: <number of attempts>
- CLI: <CLI name>
- Exit code: <code or timeout>
- Output present: <yes/no>
- Output relevance: <relevant/irrelevant/incomplete>
- Verification result: <passed/failed>
- Fallback reason: <none or specific reason>
- Pre-state baseline captured: <yes/no>
- Postcondition verified: <yes/no>
- Workspace changes: <summary>

Step 4: Kimi CLI review
- Attempt: <number of attempts>
- CLI: <CLI name>
- Exit code: <code or timeout>
- Output present: <yes/no>
- Output relevance: <relevant/irrelevant/incomplete>
- Verification result: <passed/failed>
- Fallback reason: <none or specific reason>

Failure summary:
- Failure classification(s): <none or list>
- Circuit breaker status: <closed/open/not triggered>
- Retries used: <count by step>
- Unresolved blocker: <none or description>

Self-audit (summary — see full 13-row audit above):
- Self-audit executed: <yes/no — no 则 terminal status 不能为 COMPLETED>
- Meaningful output present: <pass/fail>
- Exit code accepted: <pass/fail>
- Claims backed by evidence: <pass/fail>
- Workspace/diff verified: <pass/fail>
- No unrelated tools invoked: <pass/fail>
- Retry and circuit-breaker limits respected: <pass/fail>
- Full self-audit result: <pass/fail>
```

### Post-Completion Self-Audit（末尾审查）

**每次 4 步法结束后，必须立即执行自我审查，不可跳过。**

### 审查清单

检查以下违规项，每项回答「是/否」：

1. **Step 4 发现问题后是否直接 patch 绕过循环？** → 必须回到 Step 2→3→4，不能直接用 patch/write_file 修复
2. **Step 3 是否使用了正确的 CLI？** → Codex CLI -s danger-full-access
3. **Step 1/2 是否用了正确的 CLI？** → Step 1 和 Step 2 用 Codex CLI --ephemeral，不能用 read_file 自己审查代替
4. **所有步骤是否都调用了真实 CLI？** → 不能用 Hermes 工具（patch/write_file/terminal）代替
5. **Codex 超时/转义失败后是否走了降级路径？** → 精简提示重试 / 写 prompt 文件再 exec
6. **Step 4 复审后是否有未处理的警告？** → Step 4 指出的问题必须进入循环
7. **是否跳过了 Step 2 或 Step 4？** → 必须完整执行 4 个步骤
8. **是否在 Step 3 前声明了 CLI？** → 必须先声明 "Step 3 implementation CLI: <工具和模式>"
9. **Step 4 发现的问题是否绕过了循环直接修复？** → 必须回到 Step 2→3→4，不能直接 patch
10. **是否声称某项完成但实际上未执行对应工作？** → 每个 loop/item 必须实际执行其修复/修改，再标记完成。不得仅仅"标记完成"而不做实际代码修改或验证。用户会检查实际完成状态。Pitfall：当工作区已有未提交修改时，不要假设修复已充分——必须验证实际修改内容是否满足需求，并确认没有遗漏的并行工作项。

### 触发自我迭代

如有任意一项为「是」（违规），必须：

1. 记录违规详情（在最终回复中列出违规清单）
2. 用 `skill_manage(action='patch')` 更新 harness-4step skill 的对应章节
3. 版本号 +1
4. 在最终回复中向用户说明已修复的违规

9. **自迭代例外是否用于修复 Step 4 review finding？** → 自迭代例外只能用于修复流程执行违规，不能用于修复 Step 4 review finding

### Enhanced Self-Audit

在汇报终端状态前，必须完成以下自我审查：

| Audit item | Result |
|---|---|
| Each required step was attempted in the prescribed order | PASS / FAIL |
| 所有步骤使用了用户指定的 CLI 工具（无自动切换） | PASS / FAIL |
| 超时后未擅自降级到其他工具 | PASS / FAIL |
| Meaningful output was present after every CLI call | PASS / FAIL |
| Every CLI exit code was accepted or correctly classified | PASS / FAIL |
| Every result passed the applicable verification gate | PASS / FAIL |
| Claims in the final report are backed by CLI output or workspace evidence | PASS / FAIL |
| Workspace and git diff state were inspected where required | PASS / FAIL |
| Step 3 pre-state baseline was captured | PASS / FAIL / NOT APPLICABLE |
| Step 3 postcondition was verified | PASS / FAIL / NOT APPLICABLE |
| No unrelated or unapproved tools were invoked | PASS / FAIL |
| 每个 loop/item 标记完成前已实际执行并验证（用户会检查实际完成状态，不得仅标记完成） | PASS / FAIL |
| Retry limits were respected（用户指定工具无限重试） | PASS / FAIL |
| 因 CLI 工具本身故障导致的阻塞已正确标记为 BLOCKED_CLI_FAILURE | PASS / FAIL |
| Step 4 findings were resolved through the loop mechanism (not direct patch) | PASS / FAIL |
| 总审查（Final Review）已执行且全部 PASS | PASS / FAIL / N/A（无 loops 时） |

**任何与 CLI 绑定和降级相关的项为 FAIL，不得通过 self-audit。**

### 自审查触发器（v12.7.1 新增）

**四步法汇报模板末尾必须包含自审查结果，不得省略。** 以下为自审查的强制声明格式，必须出现在最终回复的最后一段：

```
══════════════════════════════════════════════
自审查：
- 审查清单违规项：<无 或 列出违规项>
- Self-Audit 结果：<PASS / FAIL>
- 违规原因：<如无违规则写"无">
══════════════════════════════════════════════
```

缺少此声明的汇报视为未完成自审查：终端状态必须记为 FAILED_VERIFICATION（禁止 COMPLETED），并记入违规清单。

### 技能名冲突预防（v12.9.0 新增）

GitHub 仓库已移至 `~/AppData/Local/hermes/repos/harness-4step/`（不在 skills/ 目录下，不会触发技能名冲突）。当技能名冲突仍然发生时，必须：
1. 显式声明冲突并手动解决（使用完整路径 `harness-4step/SKILL.md` 加载）
2. 运行 `skill_view(name='harness-4step/SKILL.md')` 而不是 `skill_view(name='harness-4step')`
3. 若按路径加载仍失败，**禁止依赖记忆执行**，禁止启动 Step 1，终端状态为 BLOCKED_SKILL_LOAD_FAILURE

### skill 自迭代例外

skill 文件（SKILL.md）的更新仅在修复本次执行中发现的流程执行违规时适用，例如修复违反工具限制、步骤顺序、CLI 声明或循环规则的规则缺陷。

如果 Step 4 对 SKILL.md 或其他目标内容提出任何可执行的问题、警告、缺陷或修正要求，这些发现必须进入 Step 2→3→4 循环，不得使用 `skill_manage(action='patch')` 直接修复。

自迭代例外只能用于修复流程执行违规，不能用于绕过 Step 4 review findings。即使目标文件是 SKILL.md，也必须遵守上述循环规则。

## Loops Mechanism

### 单问题循环（Step 4 FAIL 后回退）
When Step 4 fails or reports any actionable finding, warning, defect, or correction request, the process loops back to Step 2:

Step 1 -> Step 2 -> Step 3 -> Step 4
                ^               |
                |    FAIL       |
                +---------------+

Maximum Loops per problem: 10

### 递归拆分规则（v12.14.0 核心机制）

**原则：每个 to-do 项必须是原子级单问题，一个 loop 只解决一个问题。**

1. **一级拆分**：用户提出的大需求 → 拆成 N 个独立 Loop（如之前的 B1-B8）
2. **二级拆分**：如果某个 Loop 内部发现多个独立子问题 → 继续拆成 sub-loop（如 Loop 2 内发现 2a/2b/2c）
3. **三级及更深**：同理，直到每个 to-do 项满足"**单一验收目标 + 单一变更边界 + 明确文件集合 + 可独立验证**"
4. **禁止合并**：已拆分的子问题不得合并回一个大 loop 执行
5. **动态拆分**：Step 1 审查过程中发现的新问题 → 立即拆为新的 to-do 项，加入队列尾部，当前 loop 只处理原定目标

**拆分粒度标准**：
- 一个 loop = 单一验收目标对应的一个变更集合
- 跨文件修改可以属于同一个原子 loop，前提是所有文件共同服务于同一个验收目标
- 一个 CLI prompt 能完整描述该验收目标和变更边界
- 每个 loop 的 Step 1 prompt 应能在 60 秒内完成 CLI 调用

### 多问题排队修复（Pitfall — 用户强制规则）
**当同时遇到多个独立问题时，必须拆分为独立 loops 排队修复，每个 loop 聚焦一个问题，全部 loops 完成前不得停止。** 规则如下：

1. **拆分**：每个问题分配一个独立的 loop（如 Loop 1: 版本号修复、Loop 2: 主模型失效处理、Loop 3: 飞书备注策略）
2. **排队**：先建立依赖关系，按拓扑顺序执行；无依赖项再按风险排序
3. **聚焦**：每个 loop 只解决一个问题，不跨 loop 修改非目标代码
4. **完整性**：每个 loop 必须完成完整的 Step 1→2→3→4（含审核），不得跳过
5. **不中断**：全部 loops 完成前，不得向用户汇报"部分完成"或询问"是否继续"
6. **最终汇报**：所有 loops 完成后，一次性汇总汇报

**用户偏好**：当用户说"继续"或"不要打扰我"时，自动继续执行下一个 loop，不询问确认。用户明确指示"不要打扰我"时，只有在所有 CLI 工具完全不可用时才中断。不得因"需要确认优先级"或"需要用户选择"而主动停下来。保持静默执行直到所有 loops 完成。

This rule applies equally when the target is SKILL.md, another skill file, documentation, configuration, or source code.

### 循环中禁止的行为
- 禁止用 patch/write_file 直接修复 → 必须走完 Step 2→3→4
- 禁止跳过任一 CLI 步骤
- 禁止修改非本次循环目标的其他代码

6. **最终汇报**：所有 loops 完成后，一次性汇总汇报

### 总审查（Final Review，v12.14.0 新增）

**如果已触发全局熔断或步骤级熔断，不启动总审查，报告中记录 `Final Review: NOT_RUN — BLOCKED_CLI_FAILURE`。**

**正常完成全部 loops 后，必须执行一次总审查。总审查期间发生 CLI 熔断，立即停止剩余项目。**

总审查不是 Step 4（Step 4 是每个 loop 内部的复审），而是所有 loops 结束后的全局验收：

1. **完整性检查**：原始需求中的每个子问题是否都有对应的 loop 完成记录
2. **一致性检查**：修改后的文件之间是否存在冲突（如 A loop 改了 sync 的某行，B loop 又改了同一行）
3. **回归/健康检查**：执行项目适用的回归/健康检查（例如凭证池全量同步/健康检查仅作为示例）
4. **外部状态核对**：核对项目声明的外部系统或持久化状态（例如飞书记录仅作为示例）
5. **语法/编译/类型/静态检查**：按项目语言和工具链执行适用的语法/编译/类型验证或静态检查（例如 Python 的 `python -m py_compile`、TypeScript/JavaScript 的对应工具仅作为示例）
6. **无适用检查**：标记 `NOT_APPLICABLE`，并说明理由
7. **输出总报告**：包含每个 loop 的终端状态、修改文件清单、各项总审查结果

**总审查失败的处理**：
- 如果发现遗漏、冲突或回归失败 → 终端状态为 `FAILED_VERIFICATION`；如存在可执行 loop，则拆为新的 to-do 项并继续修复
- 直到总审查全部 PASS

### 循环终止条件（v12.3.0 新增）
循环在以下任一条件满足时必须终止（不等待达到最大循环数）：
1. **Circuit breaker 打开**：全局熔断触发，立即终止，终端状态 `BLOCKED_CLI_FAILURE`
2. **累计 3 步骤失败**：任何步骤的输出为空、超时或无效，累计 3 次，立即终止，终端状态 `BLOCKED_CLI_FAILURE`
3. **所有 CLI 不可用**：Codex 和 Kimi 都认证失败或工具不可用，立即终止，终端状态 `BLOCKED_CLI_FAILURE`
4. **用户取消**：用户明确要求停止，立即终止，终端状态 `CANCELLED_BY_USER`

### 禁止中途汇报中断循环（v12.2.1 新增）
Step 3 完成后必须立即进入 Step 4，**不得以"达到工具调用上限"或"需要用户确认"为由停下来汇报**。四步法是一个原子流程：
- Step 3 → Step 4 之间不允许有面向用户的中间汇报
- 即便工具调用轮次耗尽，下一轮的第一件事必须是继续 Step 4
- 违反此规则的"Step 3 完成"汇报等同于跳过 Step 4，按违规处理
- 唯一允许中断的情况：所有 CLI 工具都不可用且已穷尽降级路径

### Loop 2+ 修正模式（v12.2.3 新增）
When a loop returns to Step 2 after Step 4 review:
- Step 2 must be **ephemeral** (read-only, no file changes)
- Step 3 must use **-s danger-full-access** (full execution power)
- All previous CLI outputs are passed as context to the new prompt
- Changes from previous loops are preserved and built upon
- Loop 2+ prompt should reference the issue found in Step 4 review
- Each loop must increment the version number in skill updates

## Version History
- v12.15.0 (2026-08-01): 用户指定 Step 1/2/3 全部使用 Codex CLI，Step 4 保留 Kimi CLI；更新表格、绑定规则、Tools-in-Scope Allowlist、汇报模板、审查清单第3项、Step 2 超时备用方案章节；清理过时 Kimi CLI 引用。四步法配置最终确认：Step 1→Codex(审查)、Step 2→Codex(方案)、Step 3→Codex(执行)、Step 4→Kimi(复审)。
- v12.14.0 (2026-08-01): 通用化递归拆分与总审查规则；支持跨文件原子 loop、依赖拓扑排序和多语言验证；新增总审查熔断衔接及 FAILED_VERIFICATION/BLOCKED_CLI_FAILURE 状态映射。
- v12.13.0 (2026-07-31): 递归拆分机制：大问题→子问题→原子级 to-do 项，每个项一个 loop；拆分粒度标准（prompt 超200字则太粗）；新增总审查（Final Review）：全部 loops 完成后执行全局验收（完整性/一致性/回归/飞书终审/语法验证）；解决 CLI prompt 过长问题。
- v12.12.0 (2026-07-31): 用户指定 CLI 绑定调整：Step 1 → Kimi CLI（审查），Step 2 → Codex CLI（方案），Step 3/4 不变。更新表格、Tools-in-Scope Allowlist、汇报模板、审查清单第3项、description。
- v12.10.0 (2026-07-31): 新增"多问题拆分为独立 loops 排队修复"规则；新增"用户要求继续时不询问"规则；新增 Windows npm CLI PATH 问题章节；新增 Step 2 Kimi CLI 超时时的备用方案（基于 Step 1 Codex 审查输出）
- v12.9.0 (2026-07-31): 强化 self-audit 门禁（COMPLETED 必须附自审查声明且全 PASS），harness-4step-repo 移出 skills/ 至 repos/harness-4step 解决技能名冲突，新增 BLOCKED_SKILL_LOAD_FAILURE 终端状态
- v12.8.0 (2026-07-31): 添加 Kimi CLI Windows `.cmd` 包装器陷阱：Python subprocess 需用 `shell=True` 或 `kimi.cmd`
- v12.7.0 (2026-07-31): 重大 CLI 绑定变更：Step 2 和 Step 4 统一使用 **Kimi CLI**，彻底移除所有 MiMo Code 相关内容（MiMo CLI 语法要点、Step 3 MiMo 覆盖选项、mimo run 引用）
- v12.6.0 (2026-07-30): 重大迭代，完全满足用户 CLI 绑定诉求：
  1. **每步 CLI 绑定不可更改**：用户指定后，该步 CLI 永久固定
  2. **超时只重试不降级**：精简提示重试，禁止自动切换到其他工具
  3. **禁止自动匹配历史**：不得自动切换到之前用过的 CLI
  4. **工具故障不算违规**：CLI 本身不可用（EFTYPE、命令找不到）标记为 BLOCKED_CLI_FAILURE，不视为流程违规
  5. **Step 4 用户指定优先**：用户指定的 Step 4 CLI 必须一直用，直至完全不可用
  6. **重试机制**：用户指定的 CLI 可无限次精简重试
- v12.5.0 (2026-07-30): Updated MiMo CLI status (verified working with `xiaomi/mimo-v2.5`). Added Windows PATH pitfall (`export PATH` needed). Added MiMo timeout mitigation: per-file split execution technique. Added Step 3 user override: user can designate MiMo Code CLI for Step 3. Updated `references/mimo-cli-login.md` with current model status table and split-file execution guide.
- v12.4.0 (2026-07-30): Added Kimi CLI as Step 4 alternative (MiMo Code / Kimi CLI). Added Kimi CLI syntax section with long-prompt passing techniques (batch file + Python subprocess). Updated 4-Step Method table, Step 4 timeout handling, and Tools-in-Scope Allowlist to reflect Kimi CLI support.
- v12.3.1 (2026-07-29): Fixed loop-bypass vulnerability — "skill 自迭代例外" narrowed to process-violation-only (cannot bypass Step 4 findings loop), loop trigger widened to "actionable finding", SKILL.md explicitly subject to loop, self-audit added 14th row "Step 4 findings through loop mechanism", 审查清单 and 触发自我迭代 both added loop-bypass checks.
- v12.3.0 (2026-07-29): Added timeout/failure hardening — Result Verification Gate, Failure Classification Matrix, Circuit Breaker, Tools-in-Scope Allowlist, Terminal Statuses, Pre/Post State Capture, Enhanced Reporting Template, Enhanced Self-Audit (13 rows), Loop Termination Conditions. MiMo复审修正6项.
- v12.2.3 (2026-07-29): Added Loop 2+ correction mode for iterative fixes after Step 4 review — each loop must preserve changes and reference previous findings.
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
