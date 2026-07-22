---
name: enforce-4-step-method
description: "Enforce the 4-step method: Kimi CLI Review → MiMo Code Plan → MiMo Code Execute → Codex CLI Review"
version: 2.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [enforcement, workflow, rules, compliance]
    related_skills: [writing-plans, subagent-driven-development]
---

# Enforce 4-Step Method

## Overview

This skill enforces the 4-step method for code changes. It uses different agents for each step to ensure quality and compliance.

## The 4-Step Method

**MANDATORY for all code changes:**

| Step | Agent | Task |
|------|-------|------|
| Step 1 | Kimi CLI (K3) | Review - Analyze the problem and output findings |
| Step 2 | MiMo Code | Plan - Create implementation plan (NO code changes) |
| Step 3 | MiMo Code | Execute - Implement the plan (code changes allowed) |
| Step 4 | Codex CLI | Re-review - Verify the implementation |

## Enforcement Rules

### Rule 1: Follow the 4-Step Process

**FORBIDDEN:**
- Skipping any step
- Doing Step 2 and Step 3 together
- Modifying code without Step 1 analysis
- Not running Step 4 verification

**ALLOWED:**
- Running steps in order (1→2→3→4)
- Repeating steps if Step 4 fails (Loops)

### Rule 2: Step 1 Must Use Kimi CLI

**FORBIDDEN:**
- Using MiMo Code for Step 1
- Using Codex CLI for Step 1
- Analyzing code directly without Kimi CLI

**ALLOWED:**
- Using Kimi CLI with K3 model for complex analysis
- Using Kimi CLI with K2.7 for simple analysis

### Rule 3: Step 2 and 3 Must Use MiMo Code

**FORBIDDEN:**
- Using Kimi CLI for Step 2 or Step 3
- Using Codex CLI for Step 2 or Step 3
- Modifying code in Step 2 (only plan output)

**ALLOWED:**
- Using MiMo Code via `delegate_task`
- Step 2 outputs plan only, Step 3 executes changes

### Rule 4: Step 4 Must Use Codex CLI

**FORBIDDEN:**
- Using Kimi CLI for Step 4
- Using MiMo Code for Step 4
- Skipping Step 4 verification

**ALLOWED:**
- Using Codex CLI for comprehensive review

## Loops Mechanism

When Step 4 fails, the process loops back to Step 2:

```
Step 1 → Step 2 → Step 3 → Step 4
                ↑               │
                │    FAIL       │
                └───────────────┘
```

**Maximum Loops:** 10

**Loop Process:**
1. Step 4 reports FAIL with reasons
2. Go back to Step 2 (MiMo Code creates fix plan)
3. Step 3 implements fixes
4. Step 4 re-reviews
5. Repeat until PASS or max loops reached

## Configuration

File: `~/.hermes/harness-bindings.yaml`

```yaml
step1_review:   kimi-cli
step2_plan:     mimo
step3_execute:  mimo
step4_rereview: codex

locks:
  step1_review:   false
  step2_plan:     false
  step3_execute:  false
  step4_rereview: false
```

## Task Directory

Each task creates a directory:
```
~/.hermes/harness-workspace/YYYYMMDD-HHMMSS/
├── step1_output.txt
├── step2_output.txt
├── step3_output.txt
└── step4_output.txt
```

## Plugin Enforcement

A plugin `four-step-enforcer` is available to enforce this at the tool level:
- Location: `~/.hermes/plugins/four-step-enforcer/`
- Function: Blocks write_file/patch unless delegate_task was called first
- Tests: 14 tests passing

## Agent Capabilities

| Agent | Can Do | Cannot Do |
|-------|--------|-----------|
| Kimi CLI (Step 1/4) | Review, Analyze, Verify | Modify code |
| MiMo Code (Step 2/3) | Plan, Execute code changes | Review (Step 1/4) |
| Codex CLI (Step 4) | Review, Verify | Modify code |

## Workflow Example

```
User: Fix bug in server.js

Step 1 (Kimi CLI): 
- Analyze server.js
- Output: 3 findings with root causes

Step 2 (MiMo Code):
- Create fix plan
- Output: Implementation plan (no code)

Step 3 (MiMo Code):
- Implement fixes
- Output: Modified files

Step 4 (Codex CLI):
- Review changes
- Output: PASS or FAIL

If FAIL → Loop back to Step 2
If PASS → Done
```

## Version History

- v2.0.0 (2026-07-22): Updated to use Kimi CLI/MiMo Code/Codex CLI
- v1.0.0 (2026-07-21): Initial version with Loops mechanism
