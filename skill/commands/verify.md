---
name: code-perfection:verify
description: "Run the 8-point verification checklist — compiles, tests pass, no any, no secrets, no dead code, no scope creep"
argument-hint: "[--changed-files file1.ts file2.ts ...]"
---

EXECUTE IMMEDIATELY. No deliberation. No questions.

## Mandatory Rules

- DO NOT skip this step or treat failures as optional.
- DO NOT modify the verify script output — report it verbatim.
- DO NOT suggest "we can ignore this failure" — if it fails, it fails.

## Execution

### Step 1: Resolve SKILL_DIR

Find the code-perfection skill directory by probing in order:
- `$HOME/.claude/skills/code-perfection`
- `$HOME/.codex/skills/code-perfection`
- `$HOME/.agents/skills/code-perfection`
- `$HOME/.cursor/skills/code-perfection`
- `$HOME/.kiro/skills/code-perfection`

Use the first that contains `SKILL.md`. If NONE found, stop and report: "Code Perfection skill not installed. Run: code-perfection install"

### Step 2: Verify script exists

Check that `"$SKILL_DIR/scripts/verify.sh"` exists and is executable.

If missing: stop and report: "Verification script missing at $SKILL_DIR/scripts/verify.sh — reinstall the skill."

If not executable: run `chmod +x "$SKILL_DIR/scripts/verify.sh"` then continue.

### Step 3: Run verification

```bash
"$SKILL_DIR/scripts/verify.sh" $ARGUMENTS
```

### Step 4: Report results

- If exit code 0 (PASS): display results. Report which checks passed.
- If exit code 1 (FAIL): display results. List each specific failure. For each failure, suggest a concrete fix action (not vague advice — a specific file and change).
