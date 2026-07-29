# Session Forensics — 诊断四步法执行故障

## 适用场景

用户报告"四步法执行出错了"、"Step X 重复出现"、"生成了无关文件"、"卡住了"等故障时，使用此方法回溯会话。

## 诊断流程

### 1. 定位会话

```python
# 按关键词搜索
session_search(query="四步法 Step 2 重复 3遍 音频", limit=5, sort="newest")
session_search(query="Step 2 重复 Step 3 重复 音频")
```

### 2. 读取完整会话

```python
# 获取会话元信息（id, 消息数, 截断状态）
session_search(session_id="20260729_155645_6a4229")

# 如果 truncated=true，说明消息太多，需要滚动
```

### 3. 滚动查看中间区域

当会话有 300+ 条消息且被截断时，用 `around_message_id` 滚动：

```python
# 从关键消息附近开始
session_search(session_id="...", around_message_id=68729, window=20)
session_search(session_id="...", around_message_id=68800, window=20)
session_search(session_id="...", around_message_id=68900, window=20)
session_search(session_id="...", around_message_id=69000, window=20)
```

### 4. 重建时间线

从滚动结果中提取关键事件，按时间顺序排列：

| 时间 | 事件 | 状态 |
|------|------|------|
| 15:56 | 用户说"继续"，开始 Step 4 | ⏱️ MiMo 超时 2次 |
| 16:05 | 用户说"四步法优化" | 启动新循环 |
| 16:05 | Step 1: Codex 审查 | ⏱️ 超时，但声称完成 |
| 16:05 | Step 2: Codex 出方案 | ⏱️ 超时，但声称完成 |
| ... | ... | ... |

### 5. 识别虚假成功模式

**关键信号**：CLI 返回 exit 124（超时）但 assistant 声称"完成"。

检查每个步骤的 tool_call 输出：
- 如果 terminal 输出是 `[Command timed out after 120s]` 或 `exit 124, 1 lines output`，但 assistant 说"Step X 完成 ✅" → 虚假成功
- 检查 CLI 输出是否为空或只有帮助信息

### 6. 根因分类

| 故障类型 | 诊断依据 | 常见修复 |
|---------|---------|---------|
| CLI 超时 | exit 124，无输出 | 增加超时容错，Result Verification Gate |
| 工具混淆 | 调用了不属于当前步骤的工具 | Tools-in-Scope Allowlist，禁止 text_to_speech |
| 循环失控 | 重复执行同一步骤，无终止 | Circuit Breaker，循环终止条件 |
| 状态丢失 | context compaction 后丢失上下文 | 确保汇报模板完整，避免中间汇报 |

### 7. 输出报告

使用以下结构：

```
## 故障分析报告

### 会话追踪
**会话ID**: ...
**模型**: ...
**发生时间**: ...

### 故障时间线
| 时间 | 事件 | 状态 |
|------|------|------|

### 根因分析
1. **问题1**：分析 + 证据
2. **问题2**：分析 + 证据

### 故障分类
#### 是技能的问题：
| 问题 | 严重度 | 说明 |
|------|--------|------|

#### 不是技能的问题：
| 问题 | 原因 |
|------|------|

### 修复建议
```

## 常见陷阱

1. **context compaction 消息**：`[CONTEXT COMPACTION — REFERENCE ONLY]` 标记的消息包含旧上下文摘要，但最新用户消息才是活跃指令。不要被压缩摘要中的"未完成工作"误导去继续旧任务。

2. **子会话**：如果父会话 `parent_session_id` 不为空，说明这是 context compaction 创建的子会话，需要同时检查父会话的上下文。

3. **text_to_speech 误调用**：在 4 步法流程中，text_to_speech 调用总是无关的，应视为工具混淆。

4. **delegate_task 超时**：subagent 超时（600s）后返回 `(status=timeout)`，不要将其输出视为有效结果。

## 参考

- 故障案例：2026-07-29 会话 `20260729_155645_6a4229` — Codex 连续超时 3 次，assistant 声称成功，最后生成无关音频文件
- 修复：harness-4step v12.3.0 — Result Verification Gate、Circuit Breaker、Tools-in-Scope Allowlist