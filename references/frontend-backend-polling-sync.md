# Frontend-Backend Polling State Synchronization

## Pattern

When a frontend polls a backend for status, the frontend must poll ALL state that affects UI. If the backend has separate state variables (e.g. `isAutoRunning`, `isBillRunning`, `isDouyinRunning`), the frontend must either:

1. **Include all state in one polled endpoint** (preferred) — e.g. add `autoRunning` to `/get-process-status`
2. **Poll all relevant endpoints** — call both `/get-process-status` and `/get-auto-status`

If the frontend only polls a subset, any state change in the unpolled variables will cause UI desync (buttons stuck in wrong state).

## Real Example (2026-07-20)

**Bug**: After automation ends, "启动自动化" button stays disabled, "停止" stays active.

**Root cause**: 
- Server had `/get-process-status` (polled by frontend) and `/get-auto-status` (never polled)
- Frontend polling loop only called `/get-process-status`
- When server set `isAutoRunning=false`, frontend never learned about it
- Additionally, the polling loop had early returns when no new logs existed, meaning even adding a check AFTER the log code wouldn't run reliably

**Fix**:
1. Added `autoRunning: isAutoRunning` to `/get-process-status` response
2. Added auto status check at the TOP of the polling interval callback, BEFORE any early returns
3. Created `setAutoButtons()` helper to centralize button state management

## Key Pitfall: Early Returns in Polling Loops

Polling loops often have early returns (e.g., "if no new data, skip"). Any status check placed AFTER these returns won't run when there's no new data. Critical state checks must go BEFORE the early returns.

```
setInterval(async () => {
    // ✅ BEFORE early returns — always runs
    try {
        const status = await fetch('/get-process-status');
        if (autoRunning && !status.autoRunning) setAutoButtons(false);
    } catch {}
    
    // Early returns (skip if no new logs)
    try {
        const logs = await fetch('/get-logs');
        if (!logs.length) return;  // ← would skip any check below
        // ...
    } catch {}
}, 2000);
```

## Code Review Checklist for Polling UIs

When reviewing frontend polling code:
- [ ] Does the frontend poll ALL server-side state that affects UI?
- [ ] Are critical state checks placed BEFORE any early returns?
- [ ] Is there a centralized helper for button state (avoids scattered `disabled = true/false`)?
- [ ] Does the `/get-process-status` (or equivalent) endpoint return ALL relevant state?
- [ ] Are there separate endpoints for state that should be polled together?
