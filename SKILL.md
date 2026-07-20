---
name: harness-4step
description: |
  四步法约束框架（v2.3）。
  两层工程分离：harness（流程骨架）+ loops（迭代控制）。
  Hermes 是调度者，不分析、不改代码。
category: software-development
---

# Harness 4-Step Framework (v2.3)

## 参考文件

- `references/agent-cli-recommendation.md` — Agent CLI 能力对比与步骤推荐表
- `references/b2-loop-patterns.md` — Step 2/4 循环误判模式

## 〇、设计哲学（为什么要有四步法）

**Hermes = 便宜/免费模型做的调度器（能力弱）**
**四步法 = 用外部 Agent 补齐 Hermes 的能力短板**

Hermes 的能力短板：
- 不能可靠地分析代码找问题（Step 1）
- 不能可靠地生成修复方案（Step 2）
- 不能独立验证修改结果（Step 4）

Hermes 的能力优势：
- 能按方案执行修改（Step 3）——但需要有人告诉它改什么

**所以 Step 1/2/4 必须用外部 Agent，Step 3 可以用 Hermes 或升级到 MiMo Code。**

推荐从两个角度选择 Agent：
1. **能力加强**：哪个 Agent 在这一步能力最强
2. **性价比**：花最少钱补齐 Hermes 的短板

详见 `references/agent-cli-guide.md`

## 一、两层工程分离（最重要，用户明确要求）

```
┌─────────────────────────────────────────────────────┐
│  LAYER 1: HARNESS 工程                               │
│  定义"谁做什么"——流程骨架、Agent 绑定、锁定、角色约束  │
│  铁律：Hermes 不得绕过任何步骤                         │
├─────────────────────────────────────────────────────┤
│  LAYER 2: LOOPS 工程                                 │
│  定义"失败了怎么办"——迭代上限、收敛检测、回滚、验证     │
│  铁律：Hermes 不得在未验证时声称完成                   │
└─────────────────────────────────────────────────────┘
```

**两层独立运行，互不替代。harness 管流程正确性，loops 管迭代收敛性。**

---

## ═══════════════════════════════════════
## LAYER 1: HARNESS 工程（流程骨架）
## ═══════════════════════════════════════

### 1.1 Agent 注册表

| Agent ID     | 调用方式                                    | 能力类型     |
|--------------|---------------------------------------------|-------------|
| `codex-ssh`  | `ssh 10.0.0.50 "codex exec ..."`           | 分析+方案+复审 |
| `hermes`     | 本机 `patch()` / `write_file()`             | 仅执行修改    |
| `mimo`       | `mimo run -m mimo/mimo-auto "prompt"`       | 分析+执行     |
| `delegate`   | `delegate_task(goal="...", role="leaf")`    | 分析+执行     |

### 1.2 步骤→能力矩阵（不可违反的绑定约束）

| 步骤       | 允许绑定的 Agent ID                    | 禁止绑定的 Agent ID |
|------------|----------------------------------------|---------------------|
| step1_review | `codex-ssh` / `mimo` / `delegate`     | `hermes`            |
| step2_plan   | `codex-ssh` / `mimo` / `delegate`     | `hermes`            |
| step3_execute | 任意 4 个均可                           | 无                  |
| step4_rereview | `codex-ssh` / `mimo` / `delegate`   | `hermes`            |

**铁律：`hermes` 不能绑定到审查/方案/复审步骤（1/2/4），因为它不能分析问题。**

**Agent 选择指南：**
- **能力加强模式**：Step 1/2 用最强模型（Kimi K3 / Claude），Step 3 用 MiMo Code
- **性价比模式**：Step 1/2 用 MiMo Code（免费），Step 3 用 Hermes patch（免费）
- **均衡模式**：Step 1/2/4 用 Codex CLI（已有订阅），Step 3 用 Hermes patch
- **独立复审**：Step 4 应用不同模型族（如 Gemini），避免盲区重复

### 1.3 步骤 Agent 绑定（可配置 + 锁定）

配置文件：`~/.hermes/harness-bindings.yaml`

```yaml
step1_review:   codex-ssh
step2_plan:     codex-ssh
step3_execute:  hermes
step4_rereview: codex-ssh

locks:
  step1_review:   false
  step2_plan:     false
  step3_execute:  false
  step4_rereview: false
```

### 1.4 替换命令（精确语法）

```
解锁步骤 <步骤名>                    → 解锁
替换步骤 <步骤名> 为 <Agent ID>      → 解锁 + 替换 + 锁定
查看绑定                              → 显示状态
重置绑定                              → 恢复默认
```

**合法步骤名：** `step1_review` / `step2_plan` / `step3_execute` / `step4_rereview`
**合法 Agent ID：** `codex-ssh` / `hermes` / `mimo` / `delegate`

**校验流程：**
1. 校验步骤名合法 → 不合法则报错
2. 校验 Agent ID 合法 → 不合法则报错
3. **校验绑定不违反能力矩阵** → hermes 绑到 1/2/4 则报错
4. 全部通过才修改文件

### 1.5 四步法流程（harness 管"走不走"）

```
用户提需求
    │
    ▼
┌─ HARNESS 检查 ─────────────────────────┐
│ 1. 读 bindings.yaml                     │
│ 2. 校验 Agent ID 在注册表中              │
│ 3. 校验绑定不违反能力矩阵                │
│ 4. 确认该步未被跳过                      │
└─────────────────────────────────────────┘
    │
    ▼
Step 1: [Agent ID] 审查 → 输出 findings
    │
    ▼
Step 2: [Agent ID] 出方案 → 输出修复计划
    │
    ▼
Step 3: [Agent ID] 执行 → 按方案修改
    │
    ▼
Step 4: [Agent ID] 复审 → PASS / FAIL
    │
    ├─ PASS → 完成（harness 流程结束）
    └─ FAIL → 进入 LAYER 2 LOOPS 工程
```

### 1.6 每步的输入/输出规范（交接契约）

| 步骤 | 必需输入                    | 必需输出                      |
|------|---------------------------|------------------------------|
| Step 1 | 任务描述 + 相关文件路径      | findings 列表（编号+严重度+文件+行号+证据） |
| Step 2 | Step 1 的 findings 列表     | 修复计划（文件+位置+old→new+**验证命令**）  |
| Step 3 | Step 2 的修复计划            | 执行记录（修改文件+命令+退出码）          |
| Step 4 | Step 3 的执行记录 + 修改后文件 | 判定 PASS/FAIL + 每个 finding 的状态     |

### 1.7 Hermes 角色约束（harness 层面）

**禁止：**
- ❌ 不读源代码分析问题
- ❌ 不自己出方案、诊断、调试
- ❌ 不跳过 Step 1/2 直接改代码
- ❌ 不在 locked=true 时覆盖绑定
- ❌ 不混淆 Agent ID 和实际调用方式
- ❌ 不把 `hermes` 绑定到 Step 1/2/4

**允许：**
- ✅ 调度：读绑定 → 查注册表 → 调 Agent → 跟踪结果
- ✅ 仅在 Step 3 且绑定为 `hermes` 时：patch / write_file
- ✅ SCP / terminal 命令（文件传输、连通性检查等）
- ✅ 交接：按规范格式传递每步的输入/输出

---

## ═══════════════════════════════════════
## LAYER 2: LOOPS 工程（迭代控制）
## ═══════════════════════════════════════

### 2.1 什么时候进入 Loops

**触发条件：** Step 4 返回 FAIL
**不触发：** Step 4 返回 PASS → 直接完成，不进 loops

### 2.2 循环结构

```
Step 4 FAIL
    │
    ▼
┌─ LOOPS 检查 ──────────────────────────┐
│ 当前尝试次数 < 3 ?                      │
│   YES → 回到 Step 2（带 FAIL 的 findings）│
│   NO  → 停止循环，输出总结报告            │
└─────────────────────────────────────────┘
```

### 2.3 尝试计数

- **初始运行 = attempt 1**（Step 1→2→3→4）
- 第 1 次 FAIL → attempt 2（回 Step 2→3→4）
- 第 2 次 FAIL → attempt 3（回 Step 2→3→4）
- 第 3 次仍 FAIL → **强制停止**，输出总结：
  - 已修复的 finding 列表
  - 未修复的 finding 列表 + 原因
  - 建议用户人工介入的方向

### 2.4 收敛规则（每轮必须满足）

**同时满足以下两条才算收敛，否则提前停止：**

1. **未修复 finding 数减少：** 每轮未修复数必须比上轮减少至少 1 个
2. **关键问题必须解决：** CRITICAL 和 HIGH 级别的 finding 必须全部状态为 FIXED，否则不能 PASS

**计数规则：**
- **FIXED** → 不计入未修复数
- **PARTIAL** → 计入未修复数
- **NOT_ADDRESSED** → 计入未修复数
- **REGRESSED** → 计入未修复数 + 标记为回归
- **新引入问题** → 计入未修复数（独立于原 findings）

### 2.5 PASS/FAIL 验收标准（仅 loops 层面判定）

**PASS 必须同时满足：**
1. 无 CRITICAL 或 HIGH 级别的未修复 finding
2. 所有 MEDIUM 级别 finding 已修复或有明确"不修复"理由
3. Step 2 中指定的验证命令全部通过（exit code 0 + 输出无异常）
4. 无新引入的回归问题

**否则 FAIL**，列出需回 Step 2 的具体问题。

### 2.6 Step 3 执行保护（回滚机制）

**执行前：**
1. 确认在 git 仓库中
2. 记录当前 HEAD commit hash
3. 按方案逐个 patch

**执行后验证失败时：**
1. `git diff --name-only` 获取修改的文件列表
2. `git checkout -- <files>` 恢复这些文件
3. 报告 Step 3 失败

**注意事项：**
- 不使用 `git stash`（可能覆盖用户未提交的工作）
- 仅恢复 harness 修改的文件，不影响其他修改

### 2.7 工具级重试（区别于 review loop）

当 Agent 调用遇到瞬态错误（429/超时/网络）时：

- **最多重试 3 次**，指数退避（2s → 4s → 8s）
- 3 次仍失败 → 记录错误，报告用户，**不自动中断 loops**
- 永久性错误（认证失败/权限不足）→ 立即停止，报告用户

### 2.8 Loops 层面的禁止

- ❌ 不因单次 429/超时/工具失败就中断循环
- ❌ 不在未验证时声称"完成"
- ❌ 不跳过 Step 4 复审直接声称 PASS
- ❌ 不把"看起来修好了"等同于"验证通过"
- ❌ 不在 CRITICAL/HIGH 未修复时声称 PASS

---

## ═══════════════════════════════════════
## LAYER 3: AGENT 调用模板（两层共用）
## ═══════════════════════════════════════

### codex-ssh

```bash
# 连通性
ssh 10.0.0.50 "codex --version"

# 短 prompt（<300字符）
ssh 10.0.0.50 "codex exec 'prompt' -C 'C:\\path' \
  -m gpt-5.6-luna \
  --dangerously-bypass-approvals-and-sandbox \
  --ephemeral"

# 长 prompt：写本地文件 → SCP → Codex 读取 → 读回结果
```

**安全注意：** prompt 中的路径和文件名需转义。仅允许指定已知工作目录（`-C` 参数）。

### hermes

```
patch(path="file.js", old_string="...", new_string="...")
write_file(path="file.js", content="...")
```

**安全注意：** 仅在 Step 3 执行期间使用，且必须基于 Step 2 的批准方案。

### mimo

```bash
mimo run -m mimo/mimo-auto "prompt"
```

### delegate

```
delegate_task(goal="...", context="...", role="leaf")
```

---

## ═══════════════════════════════════════
## LAYER 4: 已知 Pitfalls
## ═══════════════════════════════════════

### SSH / 远程调用

- Windows sandbox 超时 → `--dangerously-bypass-approvals-and-sandbox`
- SSH 中文乱码 → 英文 prompt + SCP
- stdin 管道不稳定 → inline + `-o file`
- SCP 目标目录必须预先存在

### patch / 代码修改

- patch 双反斜杠 → 修改后用实际输入测试正则
- patch CRLF 验证失败 → old_string 消失 = 已生效
- 每次 patch 后必须重新 SCP 到 50
- Step 4 前验证命令必须由 Step 2 指定（不硬编码）

### Agent 混淆预防

- `codex-ssh` = `ssh 10.0.0.50 "codex exec ..."`，不是本地 `codex`
- `hermes` = patch/write_file，不是 `mimo run`
- 每次调用前确认：这个 Agent ID → 对应的调用方式是什么？

### 常见违规模式（Hermes 必须警惕）

1. **"这个修改很简单"** → 无论多简单，都必须走 harness 四步
2. **"我先看看代码找问题"** → 分析是 Step 1 的事，Hermes 不做
3. **"3 轮了还没好，我直接改吧"** → loops 停止后应报告用户，不自行修改
4. **"验证命令跑了但没仔细看输出"** → loops 层面禁止未验证就声称完成
5. **"工具 429 了，算了吧"** → 应记录失败并重试（最多 3 次），不能随意中断
6. **"我把 hermes 绑到 Step 1 试试"** → 能力矩阵禁止 hermes 绑到 1/2/4
7. **"harness 和 loops 混在一起没事"** → 必须清晰分离，否则 Hermes 会混淆职责导致违规（用户 2026-07-20 明确要求）
