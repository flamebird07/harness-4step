# GitHub Sync Workflow for harness-4step

When the user asks to "upload the latest version to GitHub", this is the workflow for syncing the local skill directory to the GitHub repo.

## Repository

- **Repo**: `flamebird07/harness-4step`
- **Default branch**: `master`
- **GitHub user**: `flamebird07`
- **Auth**: Token stored in `~/.gitconfig` URL rewrite (masked as `***`)

## Token Extraction (Windows / MSYS bash)

The gitconfig URL rewrite displays the token as `***`. `git credential fill` hangs when no credential helper is configured. Extract via Python raw bytes:

```bash
export GITHUB_TOKEN=$(python3 -c "
import re
with open('C:/Users/Administrator/.gitconfig', 'rb') as f:
    content = f.read()
m = re.search(rb'url \"https://([^@]+)@github\.com/\"', content)
print(m.group(1).decode() if m else '')
")
```

## Sync Steps

1. **Clone the repo** (if not already cloned):
   ```bash
   cd /c/Users/Administrator/AppData/Local/hermes/repos
   git clone https://github.com/flamebird07/harness-4step.git harness-4step
   ```

2. **Compare local skill files vs repo files**:
   - Local skill: `~/AppData/Local/hermes/skills/harness-4step/`
   - Local plugin: `~/AppData/Local/hermes/plugins/four-step-enforcer/`
   - Git repo: `~/AppData/Local/hermes/repos/harness-4step/`

3. **Copy updated files** into the repo:
   ```bash
   REPO=/c/Users/Administrator/AppData/Local/hermes/repos/harness-4step
   LOCAL_SKILL=/c/Users/Administrator/AppData/Local/hermes/skills/harness-4step
   LOCAL_PLUGIN=/c/Users/Administrator/AppData/Local/hermes/plugins/four-step-enforcer

   cp "$LOCAL_SKILL/SKILL.md" "$REPO/SKILL.md"
   cp "$LOCAL_SKILL/references/"*.md "$REPO/references/"
   cp "$LOCAL_SKILL/scripts/"* "$REPO/scripts/"
   cp "$LOCAL_PLUGIN/"{__init__.py,plugin.yaml,test_four_step_enforcer.py} "$REPO/plugin/"
   ```

4. **Update README.md** to reflect the new version number and file structure.

5. **Commit and push**:
   ```bash
   cd "$REPO"
   git add -A
   git commit -m "feat: 更新至 vX.X.X — <summary>"
   git push origin master
   ```

6. **Verify** via GitHub API:
   ```bash
   curl -s -H "Authorization: token $GITHUB_TOKEN" \
     "https://api.github.com/repos/flamebird07/harness-4step/commits?per_page=1" | \
     python3 -c "import sys,json; c=json.load(sys.stdin)[0]; print(c['sha'][:8], c['commit']['message'][:80])"
   ```

## File Mapping

| Local skill file | Repo location |
|-----------------|---------------|
| `skills/harness-4step/SKILL.md` | `SKILL.md` |
| `skills/harness-4step/references/*.md` | `references/*.md` |
| `skills/harness-4step/scripts/*` | `scripts/*` |
| `plugins/four-step-enforcer/__init__.py` | `plugin/__init__.py` |
| `plugins/four-step-enforcer/plugin.yaml` | `plugin/plugin.yaml` |
| `plugins/four-step-enforcer/test_four_step_enforcer.py` | `plugin/test_four_step_enforcer.py` |

## Notes

- GitHub is directly accessible from 10.0.0.87 without proxy (mihomo not required for GitHub API/git operations)
- The repo has both `master` and `main` branches — push to `master` (the default)
- MSYS `/tmp` paths don't persist between terminal calls on Windows — use Windows-native paths or in-memory Python for temp data
