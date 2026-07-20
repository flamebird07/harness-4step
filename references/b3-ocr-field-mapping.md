# B3 PDD Field Mapping Verification (2026-07-18)

## Scenario

User asks B3 to fix a semantic mismatch between PDD API fields and Feishu columns, and wants real-sample verification with 3-5 products before writing to Feishu.

## Root Cause Pattern

**DOM + API response both use anti-scrape font encryption.** The PDD backend returns PUA (Private Use Area) Unicode characters for current-period values. `parseInt("꾪")` → NaN → 0.

Fields affected:
- `payOrdrCnt` (current 30-day order count) → encrypted in API response
- `payOrdrCntPpr` (previous comparison period) → plaintext

## Critical Distinction

| Observation | Meaning | Action |
|---|---|---|
| `page.url()` contains `/login/` | Cookie actually expired | Ask user for new cookie |
| `page.url()` is the data page + JSON has PUA chars | Page loaded, values encrypted | Proceed; field mapping is semantically correct |

## Verification Strategy (When Values Are Encrypted)

1. **Map fields, not values**: verify PDD API field name → internal variable → Feishu column name
2. **Don't block** the whole task just because runtime values decrypt to 0
3. **Confirm semantic correctness**: even if the runtime value is 0 due to encryption, the field mapping is correct and will produce real numbers once encryption is bypassed

## Bad Pattern (What NOT to Do)

```
❌ "Cookie expired — cannot proceed"
✅ "Page loaded successfully; API structure intact; values encrypted by anti-scrape font"
```

## Why `*Ppr` Fields Are a Trap

The `*Ppr` (previous-period) fields return clean plaintext integers. They're tempting to use as a workaround for encryption — but they represent the **wrong time window** (previous comparison period, often a dead period with 0 orders). Using them corrupts every business decision downstream.

**Correct mapping** (`extractPddProducts`):
```js
orderCount    ← parseInt(g.payOrdrCnt, 10)       // current, conceptually correct
// NOT: parseInt(g.payOrdrCntPpr, 10)            // WRONG — previous period
```

## Feishu Write Function — Minimal Scope

B3 fix: change `'30天成交订单数': Number(product.salesCount)` to use `product.orderCount` (= `payOrdrCnt`). **One line change.** No new fields (visitor count, GMV, etc.) allowed.
