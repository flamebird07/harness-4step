---
name: harness-4step
description: "Enforce four-step code changes (v13.0.5: Step1 adds version consistency check) with locked CLI binding (Step1=mimo, Step2-3=claude, Step4=mimo), atomic to-do queue, recursive timeout splitting, evidence, and a visible report after every step."
version: 13.0.5
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [enforcement, workflow, rules, compliance, timeout]
    related_skills: [writing-plans, subagent-driven-development]
---

# Harness 4-Step Method (v13.0.5 — Claude CLI Locked Binding + Enforced Queue)

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

## 配置与仓库隔离

CLI 绑定（`binding-lock.json`、`harness-config.yaml`）是**本机配置**，不上传 GitHub。各机器可独立配置不同的 CLI 绑定，不影响仓库代码。

- 改 CLI 绑定 → 只改本机 `binding-lock.json`，不需要修改仓库
- 仓库只包含 `SKILL.md`、`run_cli.py` 等代码和文档
- 代码是配置驱动的，`run_cli.py` 从本机配置读取绑定，自动适配不同 CLI

## 版本号规则

每次修改只递增版本号最后一段（patch 位）。v13.0.0 → v13.0.1 → v13.0.2 → v13.0.3，以此类推。不修改 major 或 minor 位。

## Overview

Harnesses the 4-step method with real CLI execution. v12.3.0 adds: result verification gates after every CLI call, failure classification matrix, circuit breaker for repeated identical failures, tools-in-scope allowlist, pre/post state capture around Step 3, terminal statuses, enhanced reporting template, and enhanced self-audit. See `references/session-forensics.md` for diagnosing 4-step execution faults.

## Core Principle

**Role label != Execution.** Real CLI execution requires calling the actual tool binary — run_cli.py (locked: step1=mimo, step2-3=claude, step4=mimo). No delegating the task to a subagent and calling that "CLI execution." This skill harnesses the structured workflow to prevent process violations.

## The 4-Step Method

**MANDATORY for all code changes:**

| Step | Agent | Real CLI | Timeout | Fallback | 限制 |
|------|-------|----------|---------|----------|------|
| Step 1 | **MiMo Code CLI** | `run_cli.py --step step1` | 120s | 一次精简重试，再拆分 | 不能改代码 |
| Step 2 | **Claude Code CLI** | `run_cli.py --step step2` | 120s | 一次精简重试，再拆分 | 不能改代码 |
| Step 3 | **Claude Code CLI** | `run_cli.py --step step3` | 300s | 按已批准方案实施 | 不能做方案/审查 |
| Step 4 | **MiMo Code CLI** | `run_cli.py --step step4` | 180s | 一次精简重试，再拆分 | 不能改代码 |

## Step 1 版本号一致性审查（v13.0.5 新增）

**每次执行 Step 1 时，除了常规审查外，必须检查项目中所有文件的版本号是否一致。**

审查范围：
1. 扫描项目中所有可能包含版本号的文件（如 `package.json`、`setup.py`、`pyproject.toml`、`__version__` 变量、`version.py`、`Cargo.toml` 等）
2. 提取每个文件中的版本号声明
3. 比对所有版本号是否一致

**不一致时的处理：**
- 如果检测到版本号不一致，Step 1 必须在输出中明确列出不一致的文件及其版本号
- 版本号不一致视为 Step 1 的发现项（finding），必须在 Step 2 方案中纳入修复计划
- 版本号一致性是 Step 1 验证门的组成部分——不一致但未报告 = Step 1 验证失败

**报告格式：**
```
版本号一致性检查：
- 文件A: v1.2.3
- 文件B: v1.2.3
- 文件C: v1.2.4 <- 不一致
-> 不一致项需在 Step 2 方案中修复
```

## v13 强制执行门

1. **绑定锁**：`~/.hermes/binding-lock.json` 是唯一绑定来源。`harness-config.yaml` 不能改 agent；只有用户明确授权文本通过 `--authorize-binding-change` 记录后才可改动。
   - **诊断优先**：CLI 失败后，必须先诊断并分类失败原因（参见 Failure Classification Matrix），再考虑是否需要变更绑定。禁止在未诊断的情况下直接修改绑定来绕过失败。
2. **原子队列**：先创建 `todo.json` 并 `--todo-next` 领取 item。每个 item 必须有单一验收目标和文件范围；`--todo-id` 是运行任一步骤的必填参数。
3. **递归拆分**：同一只读步骤第二次失败/超时，item 自动标记 `split_required`；必须 `--todo-split` 生成子项，不能继续放大 prompt。
4. **顺序与完成**：队列拒绝跳步；只有 Step 1–4 均成功才可 `--todo-finish --todo-state completed`。Step 4 的新问题必须入队。
5. **逐步汇报**：`run_cli.py` 在每次成功、失败或超时后都输出 `Harness Step Report`，并把证据写入 item 历史。禁止静默 CLI 调用。
6. **反绕过插件**：插件阻止 `write_file`、`patch`、`skill_manage` 的直接修改及直接 `codex exec`/`kimi -p` 调用；代码只能经有证据的 Step 3 CLI 写入。

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

### 通用规则
1. 第一次超时 -> 精简 prompt 重试一次
2. 第二次超时 -> 执行降级路径
3. 在汇报中注明超时和降级

### 超时必重试规则
**exit 124（超时）永远不是跳过步骤的理由。** 任何 CLI 调用返回 exit 124 时：
1. 必须精简 prompt 重试一次（不可跳过重试直接进入降级）
2. 重试仍超时后，才可进入降级路径
3. 严禁将 exit 124 视为"部分成功"或"可接受的超时"而跳过步骤

### Step 1/2: Codex CLI 超时
精简版避免超时：
  codex exec -m gpt-5.6-luna --dangerously-bypass-approvals-and-sandbox --ephemeral "简短审查" 2>&1 | tail -60

**Step 2 技术只读保障：** 必须使用 `--ephemeral` 标志（沙箱环境，不保留工作区改动）。执行期间禁止任何文件修改（包括 apply、patch、write_file 操作）。执行后必须运行 `git status` 和 `git diff` 验证无变化；若检测到任何工作区改动，Step 2 视为失败，必须记录失败原因并进入重试/降级路径，不可静默保留改动。

- 不要用 delegate_task 冒充 Codex
- 不要手工写审查报告
- Step 2 输出方案文字，不调用 apply/edit 工具


### Step 3: Codex CLI 超时
降级路径：
  方案1: 写 prompt 文件再 exec
  方案2: 分段 codex exec

- 降级后仍需要验证结果
- 降级不是跳过步骤，而是换工具完成同一件事

### Step 4: Kimi CLI 超时
**降级路径（按顺序）：**
1. 短英文提示 + timeout 180s 重试一次
2. 仍失败 → 报告工具不可用，不切换其他 CLI

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
1. 必须使用真实 CLI 工具（run_cli.py，由 binding-lock.json 锁定），不能模拟
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
| **超时** | exit 124 或 timeout 异常 | 是（精简 prompt 重试 1 次） | 是（降级路径） | 否（2 次后才终止） |
| **空输出** | exit 0 但 stdout 为空 | 是（重试 1 次） | 是（降级路径） | 否（2 次后才终止） |
| **认证失败** | HTTP 401/403、auth error | 否（直接降级） | 是（换 CLI） | 如果所有 CLI 都认证失败 |
| **可执行文件失败** | EFTYPE、command not found、Missing dependency | 是（修复后重试） | 是（降级路径） | 如果修复也失败 |
| **无效输出** | 输出存在但内容不相关（如帮助信息、错误日志） | 是（精简 prompt 重试） | 是（降级路径） | 否（2 次后才终止） |

### 失败必须分类规则
**任何 CLI 失败在采取行动前，必须先通过 Failure Classification Matrix 进行分类。** 禁止在未分类失败类型的情况下直接重试、降级或终止。分类结果决定后续路径（是否可重试、是否可降级、是否终止），不得跳过分类步骤。

**重试规则**：
- 同一失败类型最多重试 1 次
- 重试后仍属于同一失败类型 → 切换到降级路径
- 降级后仍失败 → 打开 circuit breaker（见下一节）

**跨步骤失败累计**：如果累计 3 个步骤都因超时/空输出/无效输出失败，整体流程必须终止，终端状态为 `BLOCKED_CLI_FAILURE`。

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
| Step 1 | terminal（运行 run_cli.py --step step1）、write_file（写 prompt 文件）、read_file（读代码） | patch、write_file（改代码）、memory、skill_manage、text_to_speech、delegate_task（代替 CLI） |
| Step 2 | terminal（运行 run_cli.py --step step2）、write_file（写 prompt 文件）、read_file（读代码） | patch、write_file（改代码）、memory、skill_manage、text_to_speech、delegate_task（代替 CLI） |
| Step 3 | terminal（运行 run_cli.py --step step3）、write_file（写 prompt 文件）、read_file | text_to_speech、delegate_task（代替 CLI）、memory、skill_manage（非自迭代）、patch（除非在 four-step-enforcer 插件允许的绕过范围内，仅限 config.yaml/auth.json） |
| Step 4 | terminal（运行 run_cli.py --step step4）、read_file | patch、write_file、text_to_speech、delegate_task（代替 CLI） |

### 全局禁止
- **text_to_speech**：在 4 步法流程的任何步骤中，禁止调用 text_to_speech 工具。该工具与步骤目标无关，调用它会生成无关文件和混淆。
- **delegate_task 冒充 CLI**：禁止用 delegate_task 返回文本冒充 CLI 输出。delegate_task 可用于辅助任务（如并行审查），但不能替代 Step 1/2/3/4 的 CLI 调用。
- **memory 写入**：在 4 步法流程中，禁止写入 memory（自迭代 skill 更新除外）。流程结束后才能记录。

## Terminal Statuses

每次 4 步法结束时，必须分配一个明确的终端状态：

| 状态 | 含义 | 条件 |
|------|------|------|
| **COMPLETED** | 所有步骤成功完成，验证通过 | 4 个步骤都执行并验证通过，self-audit 全部 PASS |
| **BLOCKED_CLI_FAILURE** | CLI 工具不可用导致流程终止 | 所有 CLI 和降级路径都失败，或 circuit breaker 打开 |
| **FAILED_VERIFICATION** | 步骤执行了但验证未通过 | Step 3 修改后验证失败，或 Step 4 发现不可修复的问题 |
| **ABORTED_SCOPE_VIOLATION** | 超出范围或违规操作 | 修改了非目标代码，或跳过步骤，或使用禁止工具 |
| **CANCELLED_BY_USER** | 用户主动取消流程 | 用户明确要求停止，所有步骤停止 |

**终端状态不得为 COMPLETED 当：**
- 任何步骤有未验证的结果
- 有未解决的失败
- circuit breaker 处于打开状态
- 工作区状态未验证
- 用户已取消流程（应使用 `CANCELLED_BY_USER`）

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

Self-audit (summary — see full 14-row audit above):
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
2. **Step 3 是否使用了正确的 CLI？** → 以 binding-lock.json 绑定为准
3. **Step 1/2 是否用了正确的 CLI？** → 以 binding-lock.json 绑定为准
4. **所有步骤是否都调用了真实 CLI？** → 不能用 Hermes 工具（patch/write_file/terminal）代替
5. **绑定 CLI 超时/失败后是否只重试了绑定 CLI？** → 只能重试绑定 CLI，不得切换到其他工具
6. **Step 4 复审后是否有未处理的警告？** → Step 4 指出的问题必须进入循环
7. **是否跳过了 Step 2 或 Step 4？** → 必须完整执行 4 个步骤
8. **是否在每一步前都声明了 CLI？** → Step 1-4 前都必须声明对应 CLI
9. **Step 4 发现的问题是否绕过了循环直接修复？** → 必须回到 Step 2→3→4，不能直接 patch

### 触发自我迭代

如有任意一项为「是」（违规），必须：

1. 记录违规详情（在最终回复中列出违规清单）
2. 用 `skill_manage(action='patch')` 更新 harness-4step skill 的对应章节
3. 版本号 +1
4. 在最终回复中向用户说明已修复的违规

10. **Step 1 是否检查了版本号一致性？** → 必须扫描所有文件版本号并比对
11. **自迭代例外是否用于修复 Step 4 review finding？** → 自迭代例外只能用于修复流程执行违规，不能用于修复 Step 4 review finding

### Enhanced Self-Audit

在汇报终端状态前，必须完成以下自我审查：

| Audit item | Result |
|---|---|
| Each required step was attempted in the prescribed order | PASS / FAIL |
| Meaningful output was present after every CLI call | PASS / FAIL |
| Every CLI exit code was accepted or correctly classified | PASS / FAIL |
| Every result passed the applicable verification gate | PASS / FAIL |
| Claims in the final report are backed by CLI output or workspace evidence | PASS / FAIL |
| Workspace and git diff state were inspected where required | PASS / FAIL |
| Step 3 pre-state baseline was captured | PASS / FAIL / NOT APPLICABLE |
| Step 3 postcondition was verified | PASS / FAIL / NOT APPLICABLE |
| No unrelated or unapproved tools were invoked | PASS / FAIL |
| Retry limits were respected | PASS / FAIL |
| Circuit-breaker limits were respected | PASS / FAIL |
| Fallbacks were used only when permitted | PASS / FAIL |
| A valid terminal status was assigned | PASS / FAIL |
| Step 4 findings were resolved through the loop mechanism (not direct patch) | PASS / FAIL |
| Step 1 version consistency check was performed | PASS / FAIL |

**任何一项为 FAIL，不得通过 self-audit。** 成功的 self-audit 不能覆盖失败的 CLI 验证、缺失的输出、未解决的 circuit breaker 或矛盾的工作区证据。

### skill 自迭代例外

skill 文件（SKILL.md）的更新仅在修复本次执行中发现的流程执行违规时适用，例如修复违反工具限制、步骤顺序、CLI 声明或循环规则的规则缺陷。

如果 Step 4 对 SKILL.md 或其他目标内容提出任何可执行的问题、警告、缺陷或修正要求，这些发现必须进入 Step 2→3→4 循环，不得使用 `skill_manage(action='patch')` 直接修复。

自迭代例外只能用于修复流程执行违规，不能用于绕过 Step 4 review findings。即使目标文件是 SKILL.md，也必须遵守上述循环规则。

## Loops Mechanism

When Step 4 fails or reports any actionable finding, warning, defect, or correction request, the process loops back to Step 2:

Step 1 -> Step 2 -> Step 3 -> Step 4
                ^               |
                |    FAIL       |
                +---------------+

Maximum Loops: 10

This rule applies equally when the target is SKILL.md, another skill file, documentation, configuration, or source code.

### 循环中禁止的行为
- 禁止用 patch/write_file 直接修复 → 必须走完 Step 2→3→4
- 禁止跳过任一 CLI 步骤
- 禁止修改非本次循环目标的其他代码

### 循环终止条件（v12.3.0 新增）
循环在以下任一条件满足时必须终止（不等待达到最大循环数）：
1. **Circuit breaker 打开**：全局熔断触发，立即终止，终端状态 `BLOCKED_CLI_FAILURE`
2. **累计 3 步骤失败**：任何步骤的输出为空、超时或无效，累计 3 次，立即终止，终端状态 `BLOCKED_CLI_FAILURE`
3. **所有 CLI 不可用**：Codex 和 MiMo 都认证失败或工具不可用，立即终止，终端状态 `BLOCKED_CLI_FAILURE`
4. **用户取消**：用户明确要求停止，立即终止，终端状态 `CANCELLED_BY_USER`

### 禁止中途汇报中断循环（v12.2.1 新增）
Step 3 完成后必须立即进入 Step 4，**不得以"达到工具调用上限"或"需要用户确认"为由停下来汇报**。四步法是一个原子流程：
- Step 3 → Step 4 之间不允许有面向用户的中间汇报
- 即便工具调用轮次耗尽，下一轮的第一件事必须是继续 Step 4
- 违反此规则的"Step 3 完成"汇报等同于跳过 Step 4，按违规处理
- 唯一允许中断的情况：所有 CLI 工具都不可用且已穷尽降级路径

### 拆分优化（v13.0.2 新增）
当同一只读步骤（Step 1/2/4）第二次失败或超时，item 标记为 split_required，必须执行 --todo-split 生成子项，禁止继续放大 prompt。拆分遵循以下优化规则：
1. 原子性：每个子项只有一个验收目标和单一文件范围，禁止把不相关的改动塞进同一子项。
2. 无重叠：子项之间文件范围不得重叠，避免 Step 3 写冲突与验证困难。
3. 顺序执行：子项按创建顺序进入队列，队列拒绝跳步；每个子项独立完成 Step 1–4 后才能领取下一个。
4. 递归拆分：子项仍超时则继续递归拆分，不得延长超时或扩大 prompt；每次拆分必须记录理由。
5. 记录证据：在 todo.json 的 split 事件中写入拆分原因，作为汇报证据。

### 违规记录规范（v13.0.2 新增）
自我审查发现的每项流程执行违规，必须按以下规范记录，不得省略或掩盖：
1. 记录位置：在最终回复中列出违规清单；需要时把违规详情写入 item 历史作为证据。
2. 清单格式：每条违规包含「违规内容 → 违反的规则 → 修复措施」。
3. 触发自我迭代：任何违规都必须进入「触发自我迭代」流程：更新 harness-4step 对应章节、版本号 +1、在最终回复中向用户说明已修复的违规。
4. 禁止掩盖：不得为通过 self-audit 而省略违规记录；成功的 self-audit 不能覆盖已记录的违规。
5. 与 Step 4 findings 区别：违规记录针对流程执行违规；Step 4 提出的内容问题必须进入 Step 2→3→4 循环，不适用自迭代例外。

### Loop 2+ 修正模式（v12.2.3 新增）
When a loop returns to Step 2 after Step 4 review:
- Step 2 must be **ephemeral** (read-only, no file changes)
- Step 3 must use **-s danger-full-access** (full execution power)
- All previous CLI outputs are passed as context to the new prompt
- Changes from previous loops are preserved and built upon
- Loop 2+ prompt should reference the issue found in Step 4 review
- Each loop must increment the version number in skill updates

## Version History
- v13.0.5 (2026-08-05): Step 1 新增版本号一致性审查：每次执行时扫描所有文件版本号并比对，不一致项纳入 Step 2 方案修复。版本号 13.0.4 → 13.0.5。
- v13.0.4 (2026-08-05): 4 项强化：绑定锁后新增诊断优先规则；Step 2 技术只读保障强化为显式禁止文件修改+git 验证+失败处理；CLI 超时处理新增 exit 124 必重试规则；失败分类矩阵后新增强制分类规则。
- v13.0.3 (2026-08-04): Step1 绑定改为 mimo；CLI 选项内嵌到 AGENT_CLI；绑定变更通过单一 --authorize-binding-change 命令完成；版本号 13.0.2 → 13.0.3。
- v13.0.2 (2026-08-04): 新增「拆分优化」「违规记录规范」两节；版本号 13.0.1 → 13.0.2。
- v13.0.1 (2026-08-04): 新增版本号规则（每次修改只递增 patch 位）；Step4 绑定从 kimi 改为 mimo（mimo-v2.5-pro）。
- v13.0.0 (2026-08-04): 修复实际插件被全量豁免且未启用、CLI 配置可静默漂移的根因；新增 binding-lock、原子 to-do 状态机、二次只读失败强制拆分、每步报告、直接 CLI/直接写入反绕过门禁，并启用 four-step-enforcer。
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
