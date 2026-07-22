---
name: enforce-4-step-method
description: "Enforce the 4-step method: Kimi CLI Review → MiMo Code Plan → MiMo Code Execute → Codex CLI Review"
version: 2.1.0
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

## Enforcement System

### 1. Skill Rules (Prompt-based)
The SKILL.md defines rules that the LLM must follow. However, LLMs can ignore these rules.

### 2. Plugin Enforcement (Technical)
The `four-step-enforcer` plugin provides **hard technical enforcement**:
- Blocks `write_file`/`patch`/`skill_manage` calls unless `delegate_task` was called first
- Uses `pre_tool_call` and `post_tool_call` hooks
- Cannot be bypassed by LLM

### 3. Loops Mechanism
When Step 4 fails, the process loops back to Step 2:

```
Step 1 → Step 2 → Step 3 → Step 4
                ↑               │
                │    FAIL       │
                └───────────────┘
```

**Maximum Loops:** 10

## Plugin Details

### Location
- **Development:** `~/.hermes/plugins/four-step-enforcer/`
- **Installed:** `~/AppData/Local/hermes/plugins/four-step-enforcer/`

### Files
| File | Purpose |
|------|---------|
| `__init__.py` | Main plugin logic (~480 lines) |
| `plugin.yaml` | Plugin manifest |
| `test_four_step_enforcer.py` | 14 test cases |

### How It Works
```
pre_tool_call hook (before any tool call)
    │
    ├─ delegate_task → Allow (wait for post_hook to mark)
    ├─ write_file/patch/skill_manage → Check step1_done, block if False
    └─ other tools → Allow

post_tool_call hook (after any tool call)
    │
    ├─ delegate_task success → Mark step1_done=True
    └─ other → No action
```

### Configuration
In `~/AppData/Local/hermes/config.yaml`:
```yaml
plugins:
  enabled:
    - four-step-enforcer
```

### Test Results
14 tests passing:
1. Plugin loads and registers hooks
2. write_file blocked before delegate_task
3. delegate_task marks step1_done (via post_tool_call)
4. write_file allowed after delegate_task
5. patch blocked before delegate_task
6. Session isolation
7. session_id=None fallback to task_id
8. Empty status does NOT mark step1_done
9. Error does NOT mark step1_done
10. Other tools unaffected
11. TTL cleanup works
12. Max sessions limit
13. Disabled mode
14. skill_manage blocked before delegate

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

- v2.1.0 (2026-07-22): Added plugin enforcement system
- v2.0.0 (2026-07-22): Updated to use Kimi CLI/MiMo Code/Codex CLI
- v1.0.0 (2026-07-21): Initial version with Loops mechanism
