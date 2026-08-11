# Codex CLI SSH Calling Patterns (Practical Reference)

Tested and validated in production.

## Machine Setup

- 使用两台机器：控制机 / Codex 机。主机名、内网 IP、用户名、路径因环境而异，本文档统一用占位符：
  `<control-host>`（控制机）、`<codex-host>`（运行 Codex 的机器）、`<user>`（远程用户名）、
  `<home>`（远程用户主目录）、`<repo>`（项目绝对路径）、`<py>`（远程 Python 解释器绝对路径）。
- **CODEX_HOME**: `~/.ccsc/codex-mimo`（Codex 自己的数据目录，`~/.codex` 的隔离副本；目录名里的 "mimo"
  是历史会话的混淆命名，与 mimo CLI 无关——codex 和 mimo 是两个独立 CLI）。用环境变量 `CODEX_HOME`
  或默认 `~/.ccsc/codex-mimo` 指定。

## Basic One-Liner

```bash
ssh <user>@<codex-host> "codex exec '你的prompt' -C '<repo>' --dangerously-bypass-approvals-and-sandbox --ephemeral"
```

**All 3 flags are REQUIRED:**
- `--dangerously-bypass-approvals-and-sandbox` — skips interactive approval (would hang in SSH)
- `--ephemeral` — no session saved, clean each time
- `-C '<repo>'` — sets working directory on remote machine

## Handling Large Output (CRITICAL)

SSH pipe truncates long output (~32KB limit). Use `-o` to write to file, then SCP back:

```bash
# Step 1: Run Codex, output to file on remote machine
ssh <user>@<codex-host> "codex exec 'prompt' -C '<repo>' --dangerously-bypass-approvals-and-sandbox --ephemeral -o <home>\\codex_out.txt"

# Step 2: Copy result back
scp "<user>@<codex-host>:<home>\\codex_out.txt" /tmp/codex_out.txt

# Step 3: Read locally
cat /tmp/codex_out.txt
```

## Long Prompts: File + stdin (CRITICAL)

Inline prompts >500 chars in SSH commands break due to quote/special char/encoding issues. Use file+stdin:

```bash
# Step 1: Write prompt locally
write_file(path="<local>/prompt.txt", content="...long prompt...")

# Step 2: SCP prompt to remote
scp "<local>/prompt.txt" "<user>@<codex-host>:<home>\\prompt.txt"

# Step 3: Run Codex with stdin
ssh <user>@<codex-host> "Get-Content <home>\\prompt.txt -Raw | codex exec -C <home> --dangerously-bypass-approvals-and-sandbox --ephemeral -o <home>\\result.txt -"

# Step 4: Read result
scp "<user>@<codex-host>:<home>\\result.txt" "<local>\\result.txt"
```

**Why**: SSH + PowerShell + Chinese + special chars = encoding nightmare. File+stdin avoids all quoting issues.

**When to use inline**: Only for short prompts (<500 chars, no special characters, no Chinese).

## Sending Local Code to Remote Codex

When code is on the control machine but Codex is on the codex machine:

```bash
# Step 1: Merge files locally (Python)
# Read all .py files, write to a single merged text file

# Step 2: SCP to remote
scp "<local>\\merged_code.txt" "<user>@<codex-host>:<home>\\merged_code.txt"

# Step 3: Tell Codex to read the merged file
ssh <user>@<codex-host> "codex exec '代码在 <home>\\merged_code.txt，请先读取...' ..."
```

## Path Escaping Rules

Three layers of escaping needed: bash → SSH → PowerShell

| Layer | Path Format | Example |
|-------|-------------|---------|
| bash (local) | MSYS or Windows | `/<drive>/Users/<user>` or `<win-home>` |
| SSH argument | Double backslash | `<win-home>\\file.txt` |
| Inside prompt string | Double backslash | `'C:\\\\path\\\\to\\\\file'` |

**Recommendation**: Use `-C` for working directory, keep paths in prompts simple (relative or single file names).

## Common Failures and Fixes

### WebSocket TLS Error (non-blocking)
```
ERROR: tls handshake eof, url: wss://chatgpt.com/backend-api/codex/responses
warning: Falling back from WebSockets to HTTPS transport
```
This is normal — Codex auto-retries with HTTPS. The task still completes. Don't retry manually.

### PowerShell Python Path in bash
```bash
# WRONG — bash eats the backslashes
ssh <user>@<codex-host> "<py> -c 'print(1)'"

# RIGHT — quote the interpreter path
ssh <user>@<codex-host> "\"<py>\" -c 'print(1)'"
```

### Codex Reads Files Itself
Codex on the remote machine can read files directly — no need to pass file contents in the prompt. Just tell it the path:
```
codex exec '读取 <home>\\code.txt 并分析...'
```

### compileall Syntax Check
After any code generation/modification, verify syntax:
```bash
ssh <user>@<codex-host> "\"<py>\" -m compileall -q <repo>"
```

## Multi-Step Workflow (4步法)

```
# Step 1: Review (SCP code to codex machine, Codex reads and reviews)
scp local_code.txt <user>@<codex-host>:<home>/code.txt
ssh <user>@<codex-host> "codex exec '审查...' -o <home>\\review.txt ..."

# Step 2: Plan (Codex proposes fixes, same pattern)
ssh <user>@<codex-host> "codex exec '出方案...' -o <home>\\plan.txt ..."

# Step 3: Execute (MiMo Code on local machine)
mimo run -m xiaomi/mimo-v2.5-pro "..."

# Step 4: Re-review (SCP updated code, Codex verifies)
scp updated_code.txt <user>@<codex-host>:<home>/code_v2.txt
ssh <user>@<codex-host> "codex exec '复审...' -o <home>\\final.txt ..."
```

## Codex Image Analysis

Codex CLI supports `-i` flag for image input (multimodal/vision):

```bash
# Single image analysis
ssh <user>@<codex-host> "echo 'Describe this image' | codex exec -i <home>\\image.png -C <home> --dangerously-bypass-approvals-and-sandbox --ephemeral -"

# Multiple images (comparison)
ssh <user>@<codex-host> "echo 'Compare these images' | codex exec -i <home>\\img1.png -i <home>\\img2.png -C <home> --dangerously-bypass-approvals-and-sandbox --ephemeral -"
```

**⚠️ Pitfalls:**
- **prompt必须用英文**：中文通过stdin管道传入时会乱码
- **图片必须在 codex 机器上**：先SCP图片到 codex 机器，再用 `-i` 引用远程路径
- **Hermes自身vision_analyze可能429**：当mimo-v2.5-pro不支持多模态或API余额不足时，用Codex的 `-i` 作为替代方案

## Connectivity Check

```bash
# Quick check
ssh <user>@<codex-host> "codex --version"

# Full health check
ssh <user>@<codex-host> "codex doctor"
```
