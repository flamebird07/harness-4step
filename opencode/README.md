# opencode 适配层（Harness 4-Step Method）

单一项目 `flamebird07/harness-4step`，同时兼容 Hermes 与 opencode。本目录是 opencode 侧实现。

## 架构

```
harness-4step/            # GitHub 仓库（同一仓库）
├── shared/               # 唯一逻辑源（平台无关）
│   ├── core-logic.md     #   四步法逻辑/编号/绑定/循环/基线/违规
│   └── binding-recommendation.md  # 按步骤特性推荐后端
├── SKILL.md              # Hermes 适配层（run_cli.py + binding-lock.json）
└── opencode/             # opencode 适配层（本目录）
    ├── SKILL.md          #   编排规则
    ├── agents/           #   4 个独立 subagent（权限隔离）
    └── README.md
```

**规则**：逻辑优化只改 `shared/` 一次，两侧适配层只更新引用；平台细节（CLI 调用、subagent 权限、队列）各自独立进化。

## 安装到 opencode

1. 复制 skill 到全局 skill 目录：

   ```
   ~/.config/opencode/skill/four-step-harness/SKILL.md   ← 复制自 opencode/SKILL.md
   ```

2. 复制 4 个 subagent 到全局 agent 目录：

   ```
   ~/.config/opencode/agent/harness-auditor.md
   ~/.config/opencode/agent/harness-planner.md
   ~/.config/opencode/agent/harness-implementer.md
   ~/.config/opencode/agent/harness-verifier.md          ← 复制自 opencode/agents/
   ```

3. （可选）把 `shared/` 放到项目可读位置：推荐用 opencode 的
   `references` 或直接复制 `shared/core-logic.md` 到 skill 目录旁，让 subagent 能读取。

4. 重启 opencode。

## 验证

`opencode agent list` 应出现 `harness-*`；在会话里触发 `four-step-harness` skill 关键词即可被加载。

## 跨模型差异（可选）

若 opencode 配置了多个 provider/model，可在 `agents/harness-auditor.md` / `harness-verifier.md` 的
frontmatter 加 `model:` 字段升级模型，给 `harness-implementer.md` 配更快/更便宜模型。
**Step 4 与 Step 3 必须不同模型族**（`shared/core-logic.md` §4）。

## 维护

- `shared/` 变更 → 双平台自动同步（各自引用）
- opencode 适配层变更 → 只影响 opencode；Hermes 侧不受影响