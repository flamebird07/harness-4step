# DSH 动态子代理编排（DeepSeek Harness）

`harness-orchestrator`（`dsh/agents/harness-orchestrator.md`）让 DSH 的四步法按任务风险动态委派，而不是把所有工作交给一个主上下文顺序执行。

## 调度模型

| 任务情况 | 调度方式 |
| --- | --- |
| 单一、明确、低风险操作（仅只读） | 主代理直接完成。 |
| 多个独立的代码未知点 | 并行 `subagent` 调用 `harness-explorer`（`run_in_background: true`）。 |
| 多个独立模块需要找问题 | 按模块并行 `subagent` 调用 `harness-auditor`。 |
| 同一可写工作包 | 严格按审查→方案→执行→独立复审闭环。 |
| 文件归属完全独立的多个修复包 | 各自闭环可并行；禁止共享可写文件。 |

## 为什么仍保留顺序闭环

灵活委派不等于让多个代理对同一处代码自由改动。四步法的"裁判不能当运动员"仍适用于每一个修复包：审查、方案、实施和复审保持独立。灵活性来自在闭环外并行发现、按包并行，而不是取消证据链和独立验收。

## 与 CLI 绑定分派（线B）的关系

本文件描述**如何并行委派 subagent 工作包**（线A：harness-orchestrator / harness-explorer）。
每步**后端绑定到哪个 agent**（线B）由 `dsh/binding-lock.json` 决定，经 `dsh/scripts/run_step.ps1` 分派
（dsh-sub / claude / codex / mimo / kimi）。

两线正交：**编排**（谁来做、怎么拆、并行还是串行）由 orchestrator 决定；**执行后端**（每步绑哪个 agent）由
binding-lock / run_step 决定。绑定为 `dsh-sub` 时，run_step.ps1 输出 `BINDING=dsh-sub` + `SUBAGENT=<角色>`（出口码 99），
orchestrator 据此用 `subagent` 工具调度对应角色（step1→harness-auditor、step2→harness-planner、
step3→harness-implementer、step4→harness-verifier）；绑定为 CLI（claude/codex/mimo/kimi）时，run_step.ps1 直调对应 runner。

**只读限定**：orchestrator/explorer 的"直接处理"仅限只读侦察；任何可写改动必须走四步闭环，经
`run_step.ps1 -Step step3` 由实施代理完成。

**模型族约束**：step3 与 step4 的 subagent 必须不同模型族。创建时按 `dsh/binding-lock.json` 的 `models`
给 `subagent` 工具指定不同 `provider`/`model`；不满足则经 `manage_binding.ps1 -AuthorizeStep` 调整后重跑 `-Check`。

## 启用

1. 把 `dsh/SKILL.md` 安装为 DSH skill（见 `dsh/README.md`），加载 `harness-4step`。
2. 在 DSH 会话中以仓库根为工作区打开（或设置 `HARNESS_SHARED_DIR`）。
3. 主 agent 读取 `dsh/agents/harness-orchestrator.md` 作为编排行为规范。

`subagent` 工具的 `run_in_background` 用于并行侦察（true）与闭环串行步骤（false）；并行会提高模型调用量和成本。
