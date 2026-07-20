# Step 2 Timeout & Step 4 Re-SCP Patterns (B2 2026-07-16 → 2026-07-17)

## Step 2 Timeout Escalation

Codex Step 2 generates multi-batch repair plans (Batch 1-4 + extras). These are computationally heavy and frequently exceed 300s.

**Pattern:**
1. First attempt: `timeout=300`
2. If exit code 124 (timeout) or output incomplete: retry with `timeout=600`
3. The `-o` result file is still written on timeout — check completion markers before retrying

**Symptoms of incomplete Step 2 output:**
- Missing "Definition of done" section
- Truncated batch descriptions (only Batch 1-2 detailed, 3-4 stubs)
- No test specification for later batches

**Recovery:** Simply re-run with longer timeout. Result file will be overwritten with complete version.

## Post-Patch Re-SCP to 50 (CRITICAL — B2 Loop 4 Failure Mode)

Codex Step 4 复审必须基于最新文件。每次本机 patch 修改后：

```bash
cd /c/Users/Administrator/ecommerce-assistant
scp bill-manager/pdd-shop-analyzer.js Administrator@10.0.0.50:\"C:\\Users\\Administrator\\b1_baseline\\post\\pdd-shop-analyzer.js\"
scp bill-manager/server.js Administrator@10.0.0.50:\"C:\\Users\\Administrator\\b1_baseline\\post\\server.js\"
scp bill-manager/index.html Administrator@10.0.0.50:\"C:\\Users\\Administrator\\b1_baseline\\post\\index.html\"
scp /tmp/b2_v3_diff.txt Administrator@10.0.0.50:\"C:\\Users\\Administrator\\b1_baseline\\b2_v3_diff.txt\"
```

**Why Codex 会看到旧文件：**
- Step 4 prompt 引用 `C:\\Users\\Administrator\\b1_baseline\\post\\` 路径
- 如果本机改了文件但没重新 SCP，50 机器上的 post/ 目录还是旧版
- Codex 读取旧文件 → 给出错误的 "NOT ADDRESSED" 或 "PARTIAL" 结论
- 浪费一轮 Loop

**B2 实际案例（Step 4 v4 误判 → Step 4 v5 PASS）：**
- 本机 index.html 已添加 isPddMultiRunning 修改
- commit 41da2f0 后本地文件已更新，但 50 机器上的 post/index.html 仍是旧版
- Codex Step 4 v4 报告 "B1-005 polling/stop 修改缺失" → 错误 FAIL
- 重新 SCP 最新文件后，Codex Step 4 v5 确认全部修改 → PASS

**铁律：** 每次本机 patch + commit 后必须重新 SCP 全部修改文件到 50。

## Python Patch Scripts + ANSI Escape Bytes

**Root Cause:** 用 `write_file` 写 Python 脚本再 `python3 script.py` 修改 JS 文件时，`read_file` 末端的 ANSI escape bytes (`^[[H^[[2J^[[3J`) 会通过 heredoc/字符串拼接泄漏到目标文件末尾。

**Symptom:** `node --check file.js` 报 `SyntaxError: Invalid or unexpected token`，但 file.js 前 N 行看起来完全正常。

**Detection:** 跑完 patch 脚本后 **立即** 执行 `node --check`：
```bash
node --check bill-manager/pdd-shop-analyzer.js
```

**Fix (truncate trailing bytes):**
```bash
head -1143 bill-manager/pdd-shop-analyzer.js > /tmp/clean.js && mv /tmp/clean.js bill-manager/pdd-shop-analyzer.js
node --check bill-manager/pdd-shop-analyzer.js  # 应无输出 = OK
```

**Fix (append missing main() call):**
```bash
echo "" >> file.js && echo "main();" >> file.js
```

**Prevention:** 
- 每个 Python patch 脚本执行后立即 `node --check`
- 不要信任 patch "成功" 的返回码 — 独立验证
- 脚本中避免 `print(content[:N])` 这种截断输出

## main() Call Regression (Critical — B2 Loop 3 Discovery)

**Root Cause:** When using `head -N` to truncate a file, the last line may be `}` but the actual invocation is missing.

**Detection:** After EVERY truncation/rewrite of a Node.js entry-point file, verify it ends with `main();`

```bash
tail -3 bill-manager/pdd-shop-analyzer.js
# Expected: } \n \n main();
```

**Why this is critical:** If `main()` is not called, the analyzer exits immediately with no RESULT → server classifies as `MISSING_RESULT` → Codex sees REGRESSED/FAIL.

**Fix:** `echo "" >> file.js && echo "main();" >> file.js` then `node --check file.js`

## Node --Check Verification Loop

**After EVERY Step 3 (patch) cycle:**
```bash
cd /c/Users/Administrator/ecommerce-assistant
node --check bill-manager/pdd-shop-analyzer.js && echo "pdd OK"
node --check bill-manager/server.js && echo "server OK"
tail -3 bill-manager/pdd-shop-analyzer.js | grep "main();" && echo "entry OK"
```

**Do NOT proceed to Step 4 until all three pass.**

## Multi-Loop Timeline (B2 Actual, 2026-07-16 → 2026-07-17)

```
Loop 1:
  Step 1 Codex review:     ~2min (7 findings)
  Step 2 Codex plan:       ~4min (timeout=600 needed)
  Step 3 Hermes patch:     ~5min
  Step 4 Codex re-review:  ~3min → FAIL (ANSI bytes + 3 PARTIAL)
  
Loop 2 (targeted):
  Step 2 v2 plan:          ~4min
  Step 3 patch:            ~3min
  Step 4 v2 review:        ~3min → FAIL (main() not called + B1-004)
  
Loop 3 (critical fix):
  Inline fix:              ~2min (head -N + sed + add main() + fix B1-004)
  Commit 3c1a99e + 41da2f0
  
Loop 4 (verification):
  Step 4 v4 review:        ~3min → FAIL (Codex saw OLD files — SCP race)
  
Loop 5 (final verification):
  Step 4 v5 review:        ~3min → PASS (all 7 findings confirmed FIXED)
  
Total actual: ~35min for all 7 findings across 5 Codex reviews
```

## B1-004 Propagation Pattern

`markerCookieExpired` must be set `true` INSIDE the existsSync block:

```js
// WRONG - always stays false
let markerCookieExpired = false;
if (fs.existsSync(markerFile)) {
    // never set flag
}

// CORRECT
let markerCookieExpired = false;
try {
    if (fs.existsSync(markerFile)) {
        const expiredShop = fs.readFileSync(markerFile, 'utf8').trim();
        markerCookieExpired = true;  // ← INSIDE the block
        if (expiredShop) { /* cleanup */ }
    }
} catch (e) {}
```
