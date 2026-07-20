# Codex Document Verification & Revision Workflow

Use Codex to verify and correct AI-generated documents (market reports, analysis, data summaries).

## Workflow

1. **Prepare source document** — write to local file (e.g. `vietnam_source.md`)
2. **Write English verification prompt** — list specific claims to verify, ask Codex to search external sources
3. **SCP both files to 10.0.0.50**
4. **Run Codex verification** — `Get-Content prompt.txt -Raw | codex exec ... -o result.txt -`
5. **SCP result back** — read verification report
6. **Write English revision prompt** — include source doc path + all corrections from step 5
7. **SCP revision prompt to 10.0.0.50**
8. **Run Codex revision** — Codex reads source, applies corrections, writes corrected file
9. **SCP corrected file back** — verify encoding with `node -e "require('fs').readFileSync(path,'utf8')"`
10. **Copy to Obsidian** — use `node -e` on remote to avoid encoding issues

## Pitfalls

- **Always use English prompts** — Chinese via SSH stdin garbles
- **SCP files, don't pipe** — file transfer preserves UTF-8 encoding
- **Codex can search the web** — add "Use web search (curl) to check each claim against authoritative sources" to trigger external verification
- **Read results with node.js** — `Get-Content -Encoding UTF8` may still use system GBK; `node -e "require('fs').readFileSync(path,'utf8')"` is more reliable
- **Obsidian copy on same machine** — use `Copy-Item` via SSH on the target machine, don't SCP from control machine (encoding breaks)
- **Don't mix project data** — when writing to Obsidian, ensure each doc belongs to ONE project only. User caught Vietnam e-commerce data in watermark project doc.

## Output Format

Codex verification output uses these labels:
- **CORRECT** — verified by authoritative source
- **INCORRECT** — contradicts official data (provides correct data + source URL)
- **NEEDS CONTEXT** — partially correct but needs period/source clarification
- **UNVERIFIABLE** — no authoritative source found

## Example: Vietnam E-commerce Verification

15 data points verified → 4 incorrect, 5 needs context, 3 unverifiable, 3 correct.

Key corrections found:
- Platform fees were 2-3x higher than stated (old data)
- Monthly sales figure was 10x inflated (misread Chinese numeral)
- Exchange rate was ~15% off
- VAT had temporary reduction not mentioned
