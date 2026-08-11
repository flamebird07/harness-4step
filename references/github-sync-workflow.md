# GitHub Sync Workflow for harness-4step

When the user asks to "upload the latest version to GitHub", this is the workflow for syncing the local skill files to the GitHub repo.

> 安全约定：本仓库是公开仓库，**不得**在本文档或任何仓库文件中写入 token、凭据、内网 IP 或本机绝对路径。认证凭据只存在于本机 git 配置中（如 `~/.gitconfig` 的 URL rewrite 或 credential helper），仓库内不得记录凭据的存放位置或提取方法。

## Repository

- **Repo**: `flamebird07/harness-4step`
- **Default branch**: `master`
- **GitHub user**: `flamebird07`

## Sync Steps

1. **Clone the repo** (if not already cloned):
   ```bash
   git clone https://github.com/flamebird07/harness-4step.git
   ```

2. **Compare local skill files vs repo files**:
   - Local skill: `~/.hermes/skills/harness-4step/`（或平台对应安装目录）
   - Local plugin: `~/.hermes/plugins/harness-4step/`
   - Git repo: 本机 clone 目录

3. **Copy updated files** into the repo:
   ```bash
   REPO=<本机 clone 目录>
   LOCAL_SKILL=~/.hermes/skills/harness-4step
   LOCAL_PLUGIN=~/.hermes/plugins/harness-4step

   cp "$LOCAL_SKILL/SKILL.md" "$REPO/SKILL.md"
   cp "$LOCAL_SKILL/references/"*.md "$REPO/references/"
   cp "$LOCAL_SKILL/scripts/"* "$REPO/scripts/"
   cp "$LOCAL_PLUGIN/"{__init__.py,plugin.yaml,test_four_step_enforcer.py} "$REPO/plugin/"
   ```

4. **Update README.md** to reflect the new version number and file structure.

5. **Commit and push**（认证由本机 git 凭据配置提供，无需手动提取 token）:
   ```bash
   cd "$REPO"
   git add -A
   git commit -m "feat: 更新至 vX.X.X — <summary>"
   git push origin master
   ```

## File Mapping

| Local file | Repo location |
|------------|---------------|
| `skills/harness-4step/SKILL.md` | `SKILL.md` |
| `skills/harness-4step/references/*.md` | `references/*.md` |
| `skills/harness-4step/scripts/*` | `scripts/*` |
| `plugins/harness-4step/__init__.py` | `plugin/__init__.py` |
| `plugins/harness-4step/plugin.yaml` | `plugin/plugin.yaml` |
| `plugins/harness-4step/test_four_step_enforcer.py` | `plugin/test_four_step_enforcer.py` |

## Notes

- 上传前运行 `git status`，确认 `.harness/`、`baseline.diff`、`violations.log`、`backup/` 等本地产物未被加入（已在 .gitignore）。
- 推送前 grep 确认 `scripts/`、`opencode/`、`references/` 中没有本机绝对路径或内网 IP。
