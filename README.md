# 4步法强制执行系统 (Harness 4-Step Method)

> **v13.0.5** — Step 1 新增版本号一致性审查；绑定锁 + 原子队列 + 递归拆分

## 系统组成

| 组件 | 作用 |
|------|------|
| SKILL.md | 定义4步法规则和流程（v13.0.5） |
| plugin/four-step-enforcer/ | 技术强制执行插件（拦截 write_file/patch/skill_manage） |
| scripts/ | 工具脚本（run_cli.py, todo_queue.py 等） |
| references/ | 参考文档（CLI 语法、故障诊断、会话取证） |

## 快速开始

### 1. 安装技能

```bash
mkdir -p ~/.hermes/skills/harness-4step
cp SKILL.md ~/.hermes/skills/harness-4step/
cp -r scripts/ ~/.hermes/skills/harness-4step/
cp -r references/ ~/.hermes/skills/harness-4step/
```

### 2. 安装插件（技术强制执行）

```bash
mkdir -p ~/.hermes/plugins/four-step-enforcer
cp plugin/four-step-enforcer/* ~/.hermes/plugins/four-step-enforcer/
```

### 3. 启用插件

在 `~/.hermes/config.yaml` 中添加：

```yaml
plugins:
  enabled:
    - four-step-enforcer
```

### 4. 使用

在 Hermes 对话中加载技能：
```
/skill harness-4step
```

## 版本历史

- v13.0.5 (2026-08-05): Step 1 新增版本号一致性审查；修复部署 bug（插件目录结构、exempt_tools 配置）
- v13.0.3 (2026-08-04): Step1 绑定改为 mimo；CLI 选项内嵌到 AGENT_CLI
- v13.0.1 (2026-08-04): 修复实际插件被全量豁免且未启用、CLI 配置可静默漂移的根因

## 许可证

MIT
