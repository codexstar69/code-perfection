---
name: code-perfection
description: "Run the Code Perfection resolution loop — autonomous refactoring with enforced verification, revert-on-failure, and zero-regression guarantee"
argument-hint: "[target-path] [--scan-only] [--verify-only]"
---

EXECUTE IMMEDIATELY — do not deliberate, do not ask clarifying questions before reading the protocol.

## Argument Parsing (do this FIRST)

Extract from $ARGUMENTS:

- If `--scan-only` is present: scan and report issues but do not fix them
- If `--verify-only` is present: run `scripts/verify.sh` only and stop
- Everything else is the target path (default: current working directory)

## Execution

1. Resolve `SKILL_DIR` — find the code-perfection skill directory:
   - Probe: `$HOME/.claude/skills/code-perfection`, `$HOME/.codex/skills/code-perfection`, `$HOME/.agents/skills/code-perfection`, `$HOME/.cursor/skills/code-perfection`, `$HOME/.kiro/skills/code-perfection`
   - Use the first that contains `SKILL.md`

2. If `--verify-only`:
   ```bash
   "$SKILL_DIR/scripts/verify.sh" <remaining-args-after-stripping-flags>
   ```
   Pass any remaining arguments (e.g., `--changed-files file1.ts file2.ts`) to verify.sh. Stop after showing results.

3. Read the core code standards:
   ```
   Read "$SKILL_DIR/references/agents.md"
   ```

4. Read the resolution loop protocol:
   ```
   Read "$SKILL_DIR/references/resolution-loop.md"
   ```

5. Initialize the resolution loop:
   ```bash
   "$SKILL_DIR/scripts/resolution-loop.sh" init <target>
   ```

6. Scan the target — read code files, identify issues using the rules in agents.md. For each issue:
   ```bash
   "$SKILL_DIR/scripts/resolution-loop.sh" add "<file>" "<line>" "<severity>" "<description>"
   ```

7. If `--scan-only`: run `"$SKILL_DIR/scripts/resolution-loop.sh" report` and stop.

8. Enter the resolution loop:
   - Pick the highest-severity OPEN issue from `.codeperfect/issues.json`
   - `"$SKILL_DIR/scripts/resolution-loop.sh" start ISS-N`
   - Read the relevant code. Apply ONE atomic fix.
   - `"$SKILL_DIR/scripts/verify.sh"` — check the fix
   - If verify passed: `"$SKILL_DIR/scripts/resolution-loop.sh" resolve ISS-N`
   - If verify failed: `"$SKILL_DIR/scripts/resolution-loop.sh" fail ISS-N "<reason>"`
   - `"$SKILL_DIR/scripts/resolution-loop.sh" status`
   - If exit code 1: go back to "Pick the highest-severity OPEN issue"
   - If exit code 0: proceed to step 9
   - **NEVER ask "should I continue?" — the script decides.**

9. Generate the final report:
   ```bash
   "$SKILL_DIR/scripts/resolution-loop.sh" report
   ```
   Display the report to the user.
