# Enforce 4-Step Method

A Hermes skill that enforces the 4-step method for code changes: **Plan → Delegate → Review → Implement**.

## Overview

This skill prevents direct code modifications by providing technical checks and validation to ensure compliance with the 4-step workflow.

## The 4-Step Method

**MANDATORY for all code changes:**

1. **Plan** - Write implementation plan using `writing-plans` skill
2. **Delegate** - Use `delegate_task` to dispatch subagent for implementation
3. **Review** - Two-stage review (spec compliance + code quality)
4. **Implement** - Only after reviews pass

## Features

- Enforces no direct modifications to source code
- Validates git commits for compliance
- Provides pre-commit hooks
- Includes validation scripts
- Integrates with other Hermes skills

## Installation

Copy the `SKILL.md` file to your Hermes skills directory:

```bash
# For Hermes Agent
cp SKILL.md ~/.hermes/skills/software-development/enforce-4-step-method/
```

## Usage

The skill is automatically enforced when loaded. To manually check compliance:

```bash
# Check if plan exists
ls docs/plans/*.md

# Check recent commits for violations
git log --oneline --name-only HEAD~5..HEAD | grep -E '\.(py|js|ts|java|go|rs)$'
```

## Integration

This skill works with:
- `writing-plans` - For creating implementation plans
- `subagent-driven-development` - For executing plans through subagents
- `requesting-code-review` - For the two-stage review process

## License

MIT