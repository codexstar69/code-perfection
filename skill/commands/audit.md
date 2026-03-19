---
name: code-perfection:audit
description: "Full tiered codebase audit — domain-scoped scanning with cross-boundary analysis, enforced resolution loops, and persistent state for resume"
argument-hint: "[target-path] [--scan-only] [--tier <critical|high|medium|low>]"
---

EXECUTE IMMEDIATELY — do not deliberate, do not ask clarifying questions before reading the protocol.

## Argument Parsing (do this FIRST)

Extract from $ARGUMENTS:

- If `--scan-only` is present: audit and report but do not fix
- If `--tier <level>` is present: only audit domains at that tier and above
- Everything else is the target path (default: current working directory)

## Execution

1. Resolve `SKILL_DIR` — find the code-perfection skill directory:
   - Probe: `$HOME/.claude/skills/code-perfection`, `$HOME/.codex/skills/code-perfection`, `$HOME/.agents/skills/code-perfection`

2. Read all three reference files:
   ```
   Read "$SKILL_DIR/references/agents.md"
   Read "$SKILL_DIR/references/audit.md"
   Read "$SKILL_DIR/references/resolution-loop.md"
   ```

3. Run structural triage (Tier 0):
   ```bash
   "$SKILL_DIR/scripts/triage.sh" <target>
   "$SKILL_DIR/scripts/audit-state.sh" init <target>
   ```
   Read `.codeperfect/triage.json` to see the domain map.

4. Process domains in tier order (Tier 1):
   ```bash
   # Get next domain
   "$SKILL_DIR/scripts/audit-state.sh" next-domain

   # Start the domain
   "$SKILL_DIR/scripts/audit-state.sh" start-domain <name>

   # Initialize resolution loop for this domain
   "$SKILL_DIR/scripts/resolution-loop.sh" init <domain-path>

   # Read ALL files in this domain, identify issues
   # For each issue: resolution-loop.sh add ...

   # Run the resolution loop (see /code-perfection command for the loop protocol)
   # ...until resolution-loop.sh status returns exit code 0

   # Complete the domain
   "$SKILL_DIR/scripts/audit-state.sh" complete-domain <name>

   # Repeat for next domain
   ```

5. After all domains: run boundary audit (Tier 2):
   ```bash
   "$SKILL_DIR/scripts/audit-state.sh" find-boundaries <target>
   # For each boundary pair:
   "$SKILL_DIR/scripts/audit-state.sh" start-boundary <pair>
   # Read files from BOTH domains, check for contract mismatches, trust violations
   "$SKILL_DIR/scripts/audit-state.sh" complete-boundary <pair>
   ```

6. Generate the final report (Tier 3):
   ```bash
   "$SKILL_DIR/scripts/audit-state.sh" report
   ```
   Display the report to the user.

## Resume After Interruption

If the audit was interrupted:
```bash
"$SKILL_DIR/scripts/audit-state.sh" status    # See progress
"$SKILL_DIR/scripts/audit-state.sh" next-domain  # Resume from where you left off
```

The audit state file (`.codeperfect/audit-state.json`) persists progress. Domains marked `done` are never re-scanned.
