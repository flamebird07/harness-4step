# Windows CLI Pitfalls (MSYS/bash + cmd.exe + PowerShell)

Verified 2026-07-16 in production.

## 1. bash background=true Kills Node Servers (CRITICAL)

**Symptom**: `terminal(background=true, command="cd /path && node server.js")` — process starts but exits immediately when the tool call returns, or when another tool invokes bash (e.g., `claude -p`).

**Root cause**: MSYS bash's job control (`bash: no job control in this shell`) causes background processes to be reaped when the parent bash session exits.

**Fix A — Pure cmd.exe detach**:
```bash
cmd.exe /c "cd /d C:\path && start /B C:\Progra~1\nodejs\node.exe server.js > log.txt 2>&1"
```
- `start /B` launches without a new window, completely outside bash's process table
- Use `C:\Progra~1\nodejs\node.exe` (8.3 short name) to avoid space issues
- The process survives tool-call boundaries

**Fix B — PowerShell**:
```bash
powershell.exe -WindowStyle Hidden -Command "Start-Process -FilePath 'C:\Progra~1\nodejs\node.exe' -WorkingDirectory 'C:\path' -ArgumentList 'server.js' -WindowStyle Hidden"
```

**Verification**:
```bash
sleep 3 && netstat -ano | grep ":3443 "
```

## 2. `timeout /t` Doesn't Work in MSYS bash

MSYS bash `timeout` is a GNU coreutils command with different syntax (`timeout 5 command`, not `timeout /t 5`).

**Fix**: Use Windows batch `timeout` inside cmd.exe, or `sleep` (bash built-in):
```bash
# Bash — correct
sleep 5

# cmd.exe batch file — correct
timeout /t 5 /nobreak >nul

# WRONG (calling cmd's timeout from bash):
timeout /t 5    # fails with "invalid time interval"
```

## 3. `cmd.exe /c` Echo to File Gets Corrupted

Don't pipe terminal output to `server.log 2>&1` via bash — encoding and buffering issues cause garbled logs. The server itself should log to a file, or use `cmd.exe /c "command > log.txt 2>&1"`.

## 4. Git Clone from Local `.git` Directory

When GitHub is blocked (proxy required), clone from local `.git` directory for fresh-clone testing:

```bash
# Create a bundle (includes all branches)
git bundle create /tmp/repo.bundle branch-name

# Clone from bundle
git clone /tmp/repo.bundle -b branch-name new-dir

# Or clone directly from local .git
git clone /path/to/local/.git -b branch-name new-dir
```

**Note**: Untracked files (like `package-lock.json` before commit) are NOT included in the bundle. Commit first.

## 4a. git bundle for Fresh Clone Verification (P1 requirement)

When verifying P1 "fresh clone" but GitHub is unreachable:
1. `git bundle create /tmp/repo.bundle chore/dependency-baseline` (on source machine)
2. Transfer bundle to target (SCP or shared path)
3. `git clone /tmp/repo.bundle -b chore/dependency-baseline /tmp/fresh-test-dir`
4. Proceed with `npm ci`, `pip install`, etc. in the fresh directory
5. Clean up `/tmp/fresh-test-dir` and `/tmp/repo.bundle` after verification

**P1 requires**: must verify in a brand-new temporary directory, cannot use the original working directory's existing `node_modules` or Python environment.

## 5. `start /B` Window Title Quirk

`start /B "TITLE" command` — the `"TITLE"` is required when using `/B` with quoted executable paths. Without it, the first quoted argument is treated as the title:

```bash
# WRONG — "ECOM" becomes the title, not the window title
start /B "ECOM" "C:\Program Files\nodejs\node.exe" server.js

# CORRECT — empty title, then command
start /B "" "C:\Program Files\nodejs\node.exe" server.js

# SIMPLER — use 8.3 name, no quotes needed
start /B C:\Progra~1\nodejs\node.exe server.js
```

## 6. `taskkill /F /IM node.exe` Kills ALL Node Processes

Be careful — this kills every node process on the machine, including production servers. Use PID-specific kill when possible:

```bash
# Get PID from netstat
netstat -ano | grep ":3443"
# Kill specific PID
taskkill /F /PID 1234
```

## 7. `curl` in MSYS bash vs cmd.exe

MSYS bash `curl` works for HTTPS with `-k` (skip cert verification). But `%{http_code}` format specifier needs `%%` in batch files:

```bash
# Bash — single %
curl -s -o /dev/null -w "%{http_code}" https://example.com

# Batch file — double %%
curl -s -o nul -w "%%{http_code}" https://example.com
```

## 8. `netstat -ano` vs `netstat -an`

Always use `-ano` (includes PID) so you can identify which process owns a port:

```bash
netstat -ano | grep ":3443"
# TCP    0.0.0.0:3443    0.0.0.0:0    LISTENING    1234
# PID ↑
```
