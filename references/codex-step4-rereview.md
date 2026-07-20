# Codex Step 4 Re-review Workflow

Pattern for re-reviewing an existing commit against Step 1 findings and Step 2 plan.

## When to Use

- User asks to re-review a commit that was implemented without proper 4-step process
- Need to verify if actual code changes fix the approved findings

## File Preparation

1. **Extract baseline files** (before the commit):
```bash
git show <baseline_commit>:<file> > /tmp/b1_baseline/<file>
```

2. **Extract post-fix files** (after the commit):
```bash
git show <commit>:<file> > /tmp/b1_baseline/post/<file>
```

3. **Extract diff**:
```bash
git diff <baseline_commit> <commit> > /tmp/e012a5b_diff.txt
```

4. **SCP all to remote**:
```bash
ssh 10.0.0.50 "New-Item -ItemType Directory -Force -Path C:\Users\Administrator\b1_baseline\post"
scp /tmp/b1_baseline/* Administrator@10.0.0.50:"C:\Users\Administrator\b1_baseline\"
scp /tmp/b1_baseline/post/* Administrator@10.0.0.50:"C:\Users\Administrator\b1_baseline\post\"
scp /tmp/e012a5b_diff.txt Administrator@10.0.0.50:"C:\Users\Administrator\b1_baseline\e012a5b_diff.txt"
```

## Step 4 Prompt Template

```
Role: You are the independent reviewer for the ecommerce-assistant project.

Repository: C:\Users\Administrator\ecommerce-assistant
Commit under review: <commit_hash> (<commit_message>)
Baseline commit: <baseline_commit>
Task objective: Step 4 re-review — verify the actual code changes fix the approved B1 Step 1 findings and align with the Step 2 approved plan.

This is Step 4 of a four-step workflow. Review only the actual code changes.
Do not modify files.
Do not provide a repair plan.

Inspect the actual diff and source files and provide:
1. For each finding, state whether the fix is: FIXED / PARTIAL / NOT ADDRESSED / REGRESSED
2. For each finding, cite the relevant changed line numbers and evidence
3. Any new problems introduced by the changes
4. Any deviations from the approved Step 2 plan
5. Final verdict: PASS or FAIL (with specific reasons)

Be precise and evidence-based. Do not speculate without code evidence.

The diff is at C:\Users\Administrator\b1_baseline\<diff_file>
The post-fix files are at C:\Users\Administrator\b1_baseline\post\
```

## Verdict Categories

| Status | Meaning |
|--------|---------|
| FIXED | Finding fully resolved |
| PARTIAL | Partially addressed but gaps remain |
| NOT ADDRESSED | Not covered by this commit |
| REGRESSED | Change introduced a new problem for this finding |

## After FAIL

1. Document each finding's status with evidence
2. List new problems introduced
3. List deviations from Step 2 plan
4. Return to Step 2 (re-plan), do NOT patch the existing commit
