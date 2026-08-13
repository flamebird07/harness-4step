# OpenCode 动态子代理编排

`harness-orchestrator` 让 OpenCode 的四步法按任务风险动态委派，而不是把所有工作交给一个主上下文顺序执行。

## 调度模型

| 任务情况 | 调度方式 |
| --- | --- |
| 单一、明确、低风险操作（仅只读） | 主代理直接完成。 |
| 多个独立的代码未知点 | 并行调用 `harness-explorer`。 |
| 多个独立模块需要找问题 | 按模块并行调用 `harness-auditor`。 |
| 同一可写工作包 | 严格按审查→方案→执行→独立复审闭环。 |
| 文件归属完全独立的多个修复包 | 各自闭环可并行；禁止共享可写文件。 |

## 为什么仍保留顺序闭环

灵活委派不等于让多个代理对同一处代码自由改动。四步法的“裁判不能当运动员”仍适用于每一个修复包：审查、方案、实施和复审保持独立。灵活性来自在闭环外并行发现、按包并行，而不是取消证据链和独立验收。

## 与 CLI 绑定分派（线B）的关系

本文件描述**如何并行委派 subagent 工作包**（线A：harness-orchestrator / harness-explorer）。
每步**后端绑定到哪个 CLI**（线B）由 `opencode/binding-lock.json` 决定，经 `opencode/scripts/run_step.ps1` 分派
（claude/codex/mimo/kimi/opencode-sub）。

两线正交：**编排**（谁来做、怎么拆、并行还是串行）由 orchestrator 决定；**执行后端**（每步绑哪个 CLI）由
binding-lock / run_step 决定。绑定为 `opencode-sub` 时，run_step.ps1 输出 `BINDING=opencode-sub`（出口码 99），
orchestrator 据此用 Task 调度对应 subagent；绑定为 CLI（claude/codex/mimo/kimi）时，run_step.ps1 直调对应 runner。

**只读限定**：orchestrator/explorer 的"直接处理"仅限只读侦察；任何可写改动必须走四步闭环，经
`run_step.ps1 -Step step3` 由实施代理完成。

## 启用

1. 将 `opencode/opencode.json` 合并到目标项目根目录的 `opencode.json`。
2. 安装 `harness-orchestrator.md`、`harness-explorer.md` 及其余四个代理到 OpenCode 的 agents 目录。
3. 重启 OpenCode，并选择或默认使用 `harness-orchestrator`。

`subagent_depth: 2` 允许一层嵌套的专门委派；更高并发会增加模型调用量和成本。
