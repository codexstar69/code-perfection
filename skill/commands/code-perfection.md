---
name: code-perfection
description: "Run the Code Perfection resolution loop — autonomous refactoring with enforced verification, revert-on-failure, and zero-regression guarantee"
argument-hint: "[target-path] [--scan-only] [--verify-only] [--resume]"
---

EXECUTE IMMEDIATELY — do not deliberate, do not ask clarifying questions, do not summarize what you will do. Start at step 1.

## Mandatory Rules

- DO NOT ask "should I continue?" — the script decides via exit codes.
- DO NOT skip the verification step after any fix — every fix must be verified.
- DO NOT fix multiple issues in a single atomic change — one issue, one fix, one verify.
- DO NOT edit `.codeperfect/issues.json` directly — only the script modifies it.
- DO NOT commit manually — the script auto-commits on resolve.
- DO NOT modify files outside the scope of the current issue.
- DO NOT output a plan before executing — execute first, report after.
- DO NOT stop the loop early because you "think" the remaining issues are minor.

## Argument Parsing (do this FIRST)

Extract from $ARGUMENTS:

- `--scan-only`: scan and report issues but do not fix them
- `--verify-only`: run `scripts/verify.sh` only and stop
- `--resume`: resume an interrupted loop from `.codeperfect/issues.json`
- Everything else is the target path (default: current working directory)

## Execution

### Step 1: Resolve SKILL_DIR

Find the code-perfection skill directory by probing in order:
- `$HOME/.claude/skills/code-perfection`
- `$HOME/.codex/skills/code-perfection`
- `$HOME/.agents/skills/code-perfection`
- `$HOME/.cursor/skills/code-perfection`
- `$HOME/.kiro/skills/code-perfection`

Use the first that contains `SKILL.md`. If NONE contain `SKILL.md`, stop and report: "Code Perfection skill not installed. Run: code-perfection install"

### Step 2: Handle --verify-only

If `--verify-only` was set:
```bash
"$SKILL_DIR/scripts/verify.sh" <remaining-args-after-stripping-flags>
```
Display results. Stop here.

### Step 3: Handle --resume

If `--resume` was set AND `.codeperfect/issues.json` exists:
- Skip steps 4-6 (do not re-read references if already loaded, do not re-init, do not re-scan)
- Read `.codeperfect/issues.json` to see current state
- Jump directly to Step 8 (the resolution loop)

If `--resume` was set but `.codeperfect/issues.json` does NOT exist:
- Print warning: "No previous session found. Starting fresh."
- Continue to Step 4 normally.

### Step 4: Load references

Read the core code standards:
```
Read "$SKILL_DIR/references/agents.md"
```

Read the resolution loop protocol:
```
Read "$SKILL_DIR/references/resolution-loop.md"
```

If either file is missing, stop and report: "Skill files missing at $SKILL_DIR. Reinstall with: code-perfection install"

### Step 5: Initialize the resolution loop

```bash
"$SKILL_DIR/scripts/resolution-loop.sh" init <target>
```

If the script is missing or not executable, stop and report: "Script missing: $SKILL_DIR/scripts/resolution-loop.sh — reinstall the skill."

### Step 6: Scan the target

Read code files in the target. Identify issues using the rules from agents.md.

**Adaptive scanning strategy:**
- **1-5 files:** Read all files, report all issues at once.
- **6-30 files:** Read files in batches of 10. After each batch, add discovered issues before reading the next batch.
- **31+ files:** Use `/code-perfection:audit` instead. Tell the user: "Target has N files. Switching to audit mode for better coverage." Then invoke the audit command.

For each issue found, add it to the ledger:
```bash
"$SKILL_DIR/scripts/resolution-loop.sh" add "<file>" "<line>" "<severity>" "<description>"
```

Severity levels (choose the most accurate):
- `critical`: security vulnerabilities, data corruption, crash bugs
- `high`: logic errors, race conditions, resource leaks
- `medium`: dead code, type safety gaps, complexity issues
- `low`: naming, style, minor readability improvements

### Step 7: Handle --scan-only

If `--scan-only` was set:
```bash
"$SKILL_DIR/scripts/resolution-loop.sh" report
```
Display the report. Stop here.

### Step 8: Enter the resolution loop

**Progress reporting:** Before each fix, print a one-line status:
`[ISS-N] (M of T remaining) [severity] file:line — description`

Loop protocol:
1. Read `.codeperfect/issues.json` — pick the highest-severity OPEN issue
2. Print progress line (see above)
3. `"$SKILL_DIR/scripts/resolution-loop.sh" start ISS-N`
4. Read the relevant code. Apply ONE atomic fix.
5. `"$SKILL_DIR/scripts/verify.sh"` — check the fix
6. If verify passed: `"$SKILL_DIR/scripts/resolution-loop.sh" resolve ISS-N`
7. If verify failed: `"$SKILL_DIR/scripts/resolution-loop.sh" fail ISS-N "<reason from verify output>"`
8. `"$SKILL_DIR/scripts/resolution-loop.sh" status`
9. If exit code 1: go back to step 1 of this loop. DO NOT ASK THE USER.
10. If exit code 0: proceed to Step 9.
11. If exit code 2 (max iterations): proceed to Step 9.

**After a failed fix attempt:**
- Read the failure reason from the script output
- On attempt 2: try a fundamentally different approach, not a tweak
- On attempt 3: re-read the ENTIRE file before the final attempt
- After 3 failures: the script auto-defers. Move on. DO NOT try again.

### Step 9: Generate the final report

```bash
"$SKILL_DIR/scripts/resolution-loop.sh" report
```

Display the report to the user. Include:
- Total issues found / resolved / deferred
- List of deferred issues with reasons
- Any checkpoint failures encountered during the loop
