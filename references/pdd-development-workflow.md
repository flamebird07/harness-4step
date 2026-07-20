# PDD Development Workflow (B1-B4)

## B1: Status Review (Zero Code Changes)

**Goal**: Produce evidence-based assessment of PDD capabilities without modifying any code.

**Scope**:
- `pdd-login-shop.js` — login and cookie management
- `pdd-shop-analyzer.js` — scraping logic (main file, 37KB)
- `server.js` — PDD routes, RESULT handling, auto-rotation
- `index.html` — PDD UI elements
- Feishu field mapping (PDD vs Douyin)
- RESULT contract differences

**Required Outputs**:
1. Completed capabilities list with file:line evidence
2. Problems causing wrong data/wrong stops/scraping failures
3. "Extracted but not written" fields
4. Feishu field mapping table
5. User confirmation items
6. Development batches (each independently testable)
7. First batch minimal scope + rollback method

**Constraints**:
- NO code modifications
- NO MiMo Code calls
- Only Codex review + Codex planning

## B2: Core Scraping Stability

**Goal**: Fix P0/P1 issues from B1.

**Typical Batches**:
- Batch 1 (P0): API response structure tolerance
- Batch 2 (P0): Cookie validation + cookieExpired RESULT propagation
- Batch 3 (P1): DOM fallback CSS selector robustness
- Batch 4 (P1): Sort logic reliability

### ⚠️ Critical: PDD Field Semantics (Current vs Previous Period)

The PDD backend uses **two kinds of numeric fields** in the same API response:
- `payOrdrGoodsQty`, `payOrdrAmt`, `goodsUv`, `payOrdrCnt` — **current period (30-day) values** (authoritative, but rendered with anti-scrape obfuscated fonts in the DOM **and the API response itself encrypts these values with PUA Unicode characters**)
- `payOrdrGoodsQtyPpr`, `payOrdrAmtPpr`, `goodsUvPpr`, `payOrdrCntPpr` — **previous comparison-period values** (plaintext, tempting to use, but WRONG for current-period reporting)

### ⚠️ CRITICAL: PDD Current Values Are Encrypted in the API Response

**Discovery (2026-07-18, B3)**: The API JSON response for current-period fields returns PUA (Private Use Area) Unicode characters like `"꾪"` (U+EAAA) instead of digits. The encryption affects field verification — when running a sample verification script and seeing `payOrdrCnt: "꾪"`, this is NOT a login failure but anti-scrape font encryption. Don't call the whole flow "Cookie expired" when the page loaded successfully.

**Verification trap**: Check `page.url()` inside the script to confirm you're on the data page, not the login page, before declaring failure. Field-level verification (mapping) works fine; value-level verification will always show 0 due to encryption.

The `*Ppr` (previous-period) fields return clean plaintext integers (often 0 if comparing to a dead period), which makes them tempting — but they represent the WRONG time window.

**Implication**: Any code path that does `parseInt(g.payOrdrCnt)` will reliably produce 0 at runtime. The mapping is semantically correct but produces no useful data until the anti-scrape encryption is bypassed.

**Verification trap**: When you run a real-sample verification script and see `payOrdrCnt: ""`, this is **NOT** a login failure — the page loaded and responded. The API structure is intact; only the value payload is encrypted. Don't block the whole task on "Cookie expired" when the actual issue is anti-scrape encryption. Always check `page.url()` inside the script to confirm whether you're on the data page or the login page before declaring failure.

### B3 Real-Sample Verification Protocol

**User correction (2026-07-18)**: User explicitly called out that declaring "Cookie expired" based on API value encryption was wrong — the page loaded fine. For future B3-style verification:

1. **Distinguish login-failure from value-encryption**:
   - `page.url()` contains `/login/` → Cookie actually expired
   - `page.url()` is the target page + JSON response has PUA characters → page OK, values encrypted
   
2. **Map fields, not values**: B3 only verifies field-to-field mapping (PDD name → internal name → Feishu name). The actual numeric correctness is blocked by anti-scrape encryption and is out of scope. Document this limitation rather than blocking.

3. **Minimal-scope principle**: If Step 1-2 already identified a semantic mismatch (e.g., `salesCount` written to an order-count field) and Step 3 fixes it, you don't need perfect real-sample values to declare Step 4 PASS. The fix is about semantic correctness of the mapping, not the runtime value.

**Trap**: The `*Ppr` fields are plaintext numbers and `parseInt()` parses them cleanly, so the "easy" path is to use them. This produces **previous-period** data masquerading as current — corrupting every business decision downstream.

**Correct mapping** (use in `extractPddProducts`):
```
salesCount    ← parseInt(g.payOrdrGoodsQty, 10)  // NOT payOrdrGoodsQtyPpr
salesAmount   ← parseFloat(g.payOrdrAmt)         // NOT payOrdrAmtPpr
visitorCount  ← parseInt(g.goodsUv, 10)          // NOT goodsUvPpr
orderCount    ← parseInt(g.payOrdrCnt, 10)       // NOT payOrdrCntPpr
```

If `payOrdrGoodsQty` is missing/zero, the current value is genuinely unavailable — do NOT silently fall back to `*Ppr`.

### Cookie Expiry RESULT (corrected semantics)

**OLD (incorrect) guidance** — `RESULT:{"cookieExpired":true,"finished":true,...}` — this treats cookie expiry as a successful completion, which automation interprets as "shop done" and never retries. **This is a REGRESSION.**

**Correct contract**:
```json
{"success": false, "finished": false, "cookieExpired": true, "errorCode": "COOKIE_EXPIRED", "writeCount": 0, "totalProducts": 0}
```

Also set `process.exitCode = 1` and write the marker file (`cookie_expired.txt`) as a fallback for the server's close handler. The server must require `code === 0 && analyzerResult.success === true` for overall success, and must propagate `analyzerResult.cookieExpired` to the outer result.

### Sort Verification Constraint

When verifying descending order, the **sales header, column index, and sampled rows must all come from the SAME table element**. If you independently query headers across all tables and rows across all tables, header↔body pairing breaks and you can get a false "descending" result (e.g., header from table A, rows from table B that happen to be sorted differently).

### 万 Unit Handling

PDD displays large values as `1.2万` (12,000). Parsing `parseInt("1.2万".replace("万",""))` gives `1`, not `12000`. Correct parsing:
```js
const raw = text.replace(/[,]/g, '');
const val = raw.includes('万') ? parseFloat(raw) * 10000 : parseInt(raw, 10);
```

## B3: Data Field Completion

**Goal**: Add missing fields after user confirms target metrics.

**Rules**:
- Each field must document: PDD backend name, API field name, current vs previous period, unit conversion, Feishu target field, null handling
- Cannot assume `*Ppr` fields are current 30-day data until verified
- User must confirm fee structure (shipping, insurance, platform fees) — cannot reuse Douyin parameters

## B4: Profit & Automation

**Goal**: Cost matching, profit calculation, multi-shop rotation.

**Prerequisites**: B3 fields verified accurate first.

## RESULT Contract Differences

| Field | PDD | Douyin |
|---|---|---|
| `finished` | ✅ | ✅ |
| `writeCount` | ✅ | ✅ |
| `totalProducts` | ✅ | ❌ |
| `hitZeroOrder` | ❌ | ✅ |
| `cookieExpired` | ❌ (B2 fixes) | ✅ |

## Key Files

| File | Role |
|---|---|
| `pdd-login-shop.js` (5KB) | QR login, cookie save |
| `pdd-shop-analyzer.js` (37KB) | Main scraping logic |
| `server.js` PDD routes | `/get-pdd-shops`, `/run-pdd-analyzer` |
| `server.js` PDD close handler | Cookie cleanup, result propagation |
| `index.html` PDD UI | Platform toggle, login, startup |

## Common Pitfalls

1. **PDD and Douyin share `current_shop.txt`** — PDD should use `current_shop_pdd.txt` to avoid cross-contamination
2. **PDD API fields use `*Ppr` suffix** — means "previous period", current period is in encrypted DOM
3. **PDD has no built-in multi-shop mode** — frontend makes repeated calls
4. **PDD sort requires clicking icon, not header text** — header text toggles checkbox, not sort order
