---
name: code-perfection:audit
description: "Full tiered codebase audit — domain-scoped scanning with cross-boundary analysis, enforced resolution loops, and persistent state for resume"
argument-hint: "[target-path] [--scan-only] [--resume] [--tier <critical|high|medium|low>]"
---

EXECUTE IMMEDIATELY — do not deliberate, do not ask clarifying questions, do not summarize what you will do. Start at step 1.

## Mandatory Rules

- DO NOT ask "should I continue?" — the scripts decide via exit codes and state files.
- DO NOT skip domains or boundaries unless the `--tier` flag explicitly excludes them.
- DO NOT process two domains simultaneously — one domain at a time, enforced by the script.
- DO NOT edit `.codeperfect/audit-state.json` or `.codeperfect/issues.json` directly.
- DO NOT output a plan before executing — execute first, report after.
- DO NOT re-audit domains marked `done` — the script skips them automatically.
- DO NOT stop early because remaining domains look "low risk" — process all domains in scope.
- DO NOT commit manually — the resolution loop script handles commits.

## Argument Parsing (do this FIRST)

Extract from $ARGUMENTS:

- `--scan-only`: audit and report but do not fix
- `--resume`: resume from `.codeperfect/audit-state.json` (skip triage if state exists)
- `--tier <level>`: only audit domains at that tier and above (e.g., `--tier high` = CRITICAL + HIGH)
- Everything else is the target path (default: current working directory)

## Execution

### Step 1: Resolve SKILL_DIR

Find the code-perfection skill directory by probing in order:
- `$HOME/.claude/skills/code-perfection`
- `$HOME/.codex/skills/code-perfection`
- `$HOME/.agents/skills/code-perfection`
- `$HOME/.cursor/skills/code-perfection`
- `$HOME/.kiro/skills/code-perfection`

Use the first that contains `SKILL.md`. If NONE found, stop and report: "Code Perfection skill not installed. Run: code-perfection install"

### Step 2: Handle --resume

If `--resume` was set AND `.codeperfect/audit-state.json` exists:
- Skip steps 3-4 (do not re-read references unless context is empty, do not re-triage)
- Read `.codeperfect/audit-state.json` to see current progress
- Print: "Resuming audit: X domains done, Y remaining"
- Jump to Step 5 (the script's `next-domain` will pick up where it left off)

If `--resume` was set but `.codeperfect/audit-state.json` does NOT exist:
- Print: "No previous audit found. Starting fresh."
- Continue to Step 3 normally.

### Step 3: Load all three reference files

```
Read "$SKILL_DIR/references/agents.md"
Read "$SKILL_DIR/references/audit.md"
Read "$SKILL_DIR/references/resolution-loop.md"
```

If any file is missing, stop and report: "Skill files missing at $SKILL_DIR. Reinstall with: code-perfection install"

### Step 4: Run structural triage (Tier 0)

```bash
"$SKILL_DIR/scripts/triage.sh" <target>
"$SKILL_DIR/scripts/audit-state.sh" init <target>
```

Read `.codeperfect/triage.json` to see the domain map.

**Progress report:** Print domain count and tier breakdown:
`Triage complete: N domains (C critical, H high, M medium, L low)`

If `--tier <level>` was specified, note which domains are excluded:
`Filtering to <level>+ tiers. Skipping: domain1, domain2, ...`

### Step 5: Process domains in tier order (Tier 1)

**For each domain, execute this sub-loop:**

```bash
# Get next domain (handles resume automatically)
"$SKILL_DIR/scripts/audit-state.sh" next-domain
```

If output is `ALL_DOMAINS_DONE`: skip to Step 6.

If output starts with `RESUME:` or `NEXT:`: extract the domain name.

If `--tier <level>` was specified and this domain's tier is below the threshold, run:
```bash
"$SKILL_DIR/scripts/audit-state.sh" complete-domain <name>
```
Then loop back to get the next domain. DO NOT scan skipped domains.

**For each in-scope domain:**

1. Print progress: `[Domain M/N] <name> (tier: <tier>, files: <count>)`
2. `"$SKILL_DIR/scripts/audit-state.sh" start-domain <name>`
3. `"$SKILL_DIR/scripts/resolution-loop.sh" init <domain-path>`
4. Read ALL files in this domain. Identify issues using agents.md rules.
   - **Adaptive file reading:** If the domain has 50+ files, read in batches of 15. Add issues after each batch.
   - For each issue: `"$SKILL_DIR/scripts/resolution-loop.sh" add "<file>" "<line>" "<severity>" "<description>"`
5. If `--scan-only`: run `"$SKILL_DIR/scripts/resolution-loop.sh" report`, then skip to step 8.
6. **Run the resolution loop** (same protocol as `/code-perfection` Step 8):
   - Pick highest-severity OPEN issue
   - Print: `  [ISS-N] (M of T remaining) [severity] file:line — description`
   - `start ISS-N` -> fix -> `verify.sh` -> `resolve` or `fail` -> `status`
   - If exit code 1: continue loop. DO NOT ASK.
   - If exit code 0 or 2: exit the loop.
7. After loop exits: print domain summary: `  Domain <name>: found=X resolved=Y deferred=Z`
8. `"$SKILL_DIR/scripts/audit-state.sh" complete-domain <name>`
9. Go back to the top of Step 5 to get the next domain.

### Step 6: Cross-domain boundary audit (Tier 2)

```bash
"$SKILL_DIR/scripts/audit-state.sh" find-boundaries <target>
```

Read the boundary pairs from `.codeperfect/audit-state.json`.

**For each boundary pair:**
1. `"$SKILL_DIR/scripts/audit-state.sh" start-boundary <pair>`
2. Read files from BOTH domains in the pair simultaneously
3. Check for: trust boundary violations, contract mismatches, race conditions, auth gaps, partial failure states
4. If issues found and NOT `--scan-only`: fix them using the resolution loop
5. `"$SKILL_DIR/scripts/audit-state.sh" complete-boundary <pair>`

If no boundaries found, print: "No cross-domain boundaries detected. Skipping Tier 2."

### Step 7: Generate the final report (Tier 3)

```bash
"$SKILL_DIR/scripts/audit-state.sh" report
```

Display the full report to the user. Include:
- Per-domain summary table
- Cross-boundary findings
- Coverage status (complete/partial)
- Total resolved / deferred across all domains

## Resume After Interruption

If the audit is interrupted at any point:
1. All progress is saved in `.codeperfect/audit-state.json`
2. Domains marked `done` are never re-scanned
3. Re-run with `--resume` to continue from where the audit left off:
   ```
   /code-perfection:audit --resume <target>
   ```
4. The `next-domain` command automatically finds the first `in_progress` or `pending` domain

## Context Loss Recovery

If you lose track of where you are mid-audit:
1. Run `"$SKILL_DIR/scripts/audit-state.sh" status` to see full progress
2. Run `"$SKILL_DIR/scripts/audit-state.sh" next-domain` to find what to do next
3. If a domain shows `in_progress`, resume the resolution loop for that domain
4. If all domains show `done`, proceed to boundary audit (Step 6)
5. The state file is the SINGLE SOURCE OF TRUTH — not your memory
