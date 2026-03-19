---
name: code-perfection:verify
description: "Run the 8-point verification checklist — compiles, tests pass, no any, no secrets, no dead code, no scope creep"
argument-hint: "[--changed-files file1.ts file2.ts ...]"
---

EXECUTE IMMEDIATELY.

## Execution

1. Resolve `SKILL_DIR` — find the code-perfection skill directory:
   - Probe: `$HOME/.claude/skills/code-perfection`, `$HOME/.codex/skills/code-perfection`, `$HOME/.agents/skills/code-perfection`

2. Run the verification script:
   ```bash
   "$SKILL_DIR/scripts/verify.sh" $ARGUMENTS
   ```

3. Display the results to the user. If verification failed (exit code 1), list the specific failures and suggest fixes.
