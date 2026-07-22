# 4步法强制执行系统

> ⚠️ **迁移声明**：本仓库已整合 `enforce-4-step-method` 的插件代码。
> 完整的 4 步法系统（skill + plugin + references）现在都在此仓库中。
> `enforce-4-step-method` 仓库已归档，不再维护。

## 系统组成

| 组件 | 作用 |
|------|------|
| SKILL.md | 定义4步法规则和流程 |
| plugin/ | 技术强制执行插件 |
| references/ | 参考文档 |
| scripts/ | 工具脚本 |

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

### 2. 安装Skill
```bash
# 复制SKILL.md到skills目录
cp SKILL.md ~/AppData/Local/hermes/skills/harness-4step/
```

### 3. 验证
```bash
# 检查插件加载
hermes plugins list

# 运行测试
cd ~/AppData/Local/hermes/plugins/four-step-enforcer
python test_four_step_enforcer.py
```

## 4步法流程

| 步骤 | Agent | 任务 |
|------|-------|------|
| Step 1 | Kimi CLI (K3) | 审查 - 分析问题 |
| Step 2 | MiMo Code | 方案 - 制定计划 |
| Step 3 | MiMo Code | 执行 - 实施修改 |
| Step 4 | Codex CLI | 复审 - 验证结果 |

## 文件结构

```
harness-4step/
├── README.md                    # 项目介绍
├── SKILL.md                     # Hermes技能定义
├── MIGRATION.md                 # 迁移说明
├── plugin/
│   ├── __init__.py              # 插件主代码
│   ├── plugin.yaml              # 插件元数据
│   └── test_four_step_enforcer.py  # 测试文件
├── references/                  # 参考文档
└── scripts/
    └── regex-verify.js
```

## 版本历史

- v2.0.0 (2026-07-22): 整合两个仓库，添加插件强制执行系统
- v1.0.0 (2026-07-21): 初始版本
