# Codex CLI SSH Calling Patterns (Practical Reference)

Tested and validated in production 2026-07-11.

## Machine Setup
- **Control machine**: 10.0.0.87 (周公瑾, Windows, bash/MSYS)
- **Codex machine**: 10.0.0.50 (郭奉孝, Windows, PowerShell)
- **Codex version**: 0.144.1, model: gpt-5.6-sol, auth: ChatGPT tokens
- **CODEX_HOME**: `C:\Users\Administrator\.ccsc\codex-mimo`

## Basic One-Liner

```bash
ssh 10.0.0.50 "codex exec '你的prompt' -C 'C:\\path\\to\\project' --dangerously-bypass-approvals-and-sandbox --ephemeral"
```

**All 3 flags are REQUIRED:**
- `--dangerously-bypass-approvals-and-sandbox` — skips interactive approval (would hang in SSH)
- `--ephemeral` — no session saved, clean each time
- `-C 'path'` — sets working directory on remote machine

## Handling Large Output (CRITICAL)

SSH pipe truncates long output (~32KB limit). Use `-o` to write to file, then SCP back:

```bash
# Step 1: Run Codex, output to file on remote machine
ssh 10.0.0.50 "codex exec 'prompt' -C 'path' --dangerously-bypass-approvals-and-sandbox --ephemeral -o C:\\Users\\Administrator\\codex_out.txt"

# Step 2: Copy result back
scp "10.0.0.50:C:\Users\Administrator\codex_out.txt" /tmp/codex_out.txt

# Step 3: Read locally
cat /tmp/codex_out.txt
```

## Long Prompts: File + stdin (CRITICAL)

Inline prompts >500 chars in SSH commands break due to quote/special char/encoding issues. Use file+stdin:

```bash
# Step 1: Write prompt locally
write_file(path="C:/Users/Administrator/prompt.txt", content="...long prompt...")

# Step 2: SCP prompt to remote
scp "C:\Users\Administrator\prompt.txt" "10.0.0.50:C:\Users\Administrator\prompt.txt"

# Step 3: Run Codex with stdin
ssh 10.0.0.50 "Get-Content C:\Users\Administrator\prompt.txt -Raw | codex exec -C C:\Users\Administrator --dangerously-bypass-approvals-and-sandbox --ephemeral -o C:\Users\Administrator\result.txt -"

# Step 4: Read result
scp "10.0.0.50:C:\Users\Administrator\result.txt" "C:\Users\Administrator\result.txt"
```

**Why**: SSH + PowerShell + Chinese + special chars = encoding nightmare. File+stdin avoids all quoting issues.

**When to use inline**: Only for short prompts (<500 chars, no special characters, no Chinese).

## Sending Local Code to Remote Codex

When code is on 10.0.0.87 but Codex is on 10.0.0.50:

```bash
# Step 1: Merge files locally (Python)
# Read all .py files, write to a single merged text file

# Step 2: SCP to remote
scp "C:\Users\Administrator\merged_code.txt" "10.0.0.50:C:\Users\Administrator\merged_code.txt"

# Step 3: Tell Codex to read the merged file
ssh 10.0.0.50 "codex exec '代码在 C:\\Users\\Administrator\\merged_code.txt，请先读取...' ..."
```

## Path Escaping Rules

Three layers of escaping needed: bash → SSH → PowerShell

| Layer | Path Format | Example |
|-------|-------------|---------|
| bash (local) | MSYS or Windows | `/c/Users/Admin` or `C:\Users\Admin` |
| SSH argument | Double backslash | `C:\\Users\\Administrator\\file.txt` |
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
ssh 10.0.0.50 "C:\Users\Administrator\AppData\Local\Programs\Python\Python310\python.exe -c 'print(1)'"

# RIGHT — use quotes
ssh 10.0.0.50 "\"C:/Users/Administrator/AppData/Local/Programs/Python/Python310/python.exe\" -c 'print(1)'"
```

### Codex Reads Files Itself
Codex on the remote machine can read files directly — no need to pass file contents in the prompt. Just tell it the path:
```
codex exec '读取 C:\\Users\\Administrator\\code.txt 并分析...'
```

### compileall Syntax Check
After any code generation/modification, verify syntax:
```bash
ssh 10.0.0.50 "\"C:/Users/Administrator/AppData/Local/Programs/Python/Python310/python.exe\" -m compileall -q C:\\Users\\Administrator\\project"
```

## Multi-Step Workflow (4步法)

```
# Step 1: Review (SCP code to 50, Codex reads and reviews)
scp local_code.txt 10.0.0.50:C:/Users/Administrator/code.txt
ssh 10.0.0.50 "codex exec '审查...' -o C:\\Users\\Administrator\\review.txt ..."

# Step 2: Plan (Codex proposes fixes, same pattern)
ssh 10.0.0.50 "codex exec '出方案...' -o C:\\Users\\Administrator\\plan.txt ..."

# Step 3: Execute (MiMo Code on local machine)
mimo run -m mimo/mimo-auto "..."

# Step 4: Re-review (SCP updated code, Codex verifies)
scp updated_code.txt 10.0.0.50:C:/Users/Administrator/code_v2.txt
ssh 10.0.0.50 "codex exec '复审...' -o C:\\Users\\Administrator\\final.txt ..."
```

## Codex Image Analysis

Codex CLI supports `-i` flag for image input (multimodal/vision):

```bash
# Single image analysis
ssh 10.0.0.50 "echo 'Describe this image' | codex exec -i C:\\Users\\Administrator\\image.png -C C:\\Users\\Administrator --dangerously-bypass-approvals-and-sandbox --ephemeral -"

# Multiple images (comparison)
ssh 10.0.0.50 "echo 'Compare these images' | codex exec -i C:\\Users\\Administrator\\img1.png -i C:\\Users\\Administrator\\img2.png -C C:\\Users\\Administrator --dangerously-bypass-approvals-and-sandbox --ephemeral -"
```

**⚠️ Pitfalls:**
- **prompt必须用英文**：中文通过stdin管道传入时会乱码
- **图片必须在50机器上**：先SCP图片到50，再用 `-i` 引用远程路径
- **Hermes自身vision_analyze可能429**：当mimo-v2.5-pro不支持多模态或API余额不足时，用Codex的 `-i` 作为替代方案

## Connectivity Check

```bash
# Quick check
ssh 10.0.0.50 "codex --version"
# Expected: codex-cli 0.144.1

# Full health check
ssh 10.0.0.50 "codex doctor"
```
