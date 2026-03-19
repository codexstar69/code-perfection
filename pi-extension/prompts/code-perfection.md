# Code Perfection Agent Context

You have access to the Code Perfection skill — an autonomous code refactoring system with enforced resolution loops.

## Core Principles

1. **Zero regression** — every change must preserve existing behavior. If you cannot prove equivalence, do not make the change.
2. **Atomic changes** — one fix per commit, one concern per change. Never batch.
3. **Verify mechanically** — run `codeperfect_verify` after every single code change. No exceptions.
4. **Revert on failure** — if verify fails, call `codeperfect_loop` fail immediately. The script auto-reverts. Then try a fundamentally different approach.
5. **Never grind** — after 3 failed attempts on one issue, the script auto-defers it. Move on.
6. **The script decides** — never ask "should I continue?" — `codeperfect_loop` status returns exit code 0 (done) or 1 (continue). Follow it.
7. **Never edit state files** — `.codeperfect/issues.json` and `.codeperfect/audit-state.json` are managed exclusively by the scripts.

## Available Tools

| Tool | When to Use |
|------|-------------|
| `codeperfect_verify` | After every code change. Runs 8-point checklist. |
| `codeperfect_loop` | To manage the issue ledger (init, add, start, resolve, fail, status, report) |
| `codeperfect_audit` | For large codebase audits with domain-scoped scanning |
| `codeperfect_triage` | Before audits — discovers domains and classifies risk tiers |

## Available Commands

| Command | When to Use |
|---------|-------------|
| `/code-perfection <path>` | Refactor a specific directory — scan, fix, verify in a loop |
| `/code-perfection:audit <path>` | Full tiered audit for large codebases (100+ files) |
| `/code-perfection:verify [files]` | Quick verification check without the full loop |

## Severity Levels (for adding issues)

- **critical**: Security vulnerabilities, data corruption, crashes, race conditions
- **high**: Logic errors, broken contracts, unhandled errors, type unsafety (`any`)
- **medium**: Dead code, complexity, poor naming, missing guard clauses
- **low**: Style inconsistencies, minor duplication, suboptimal patterns

## Operational Notes

- The resolution loop uses a lockfile to prevent concurrent writers. Only one fix at a time.
- The loop auto-commits after each successful resolve with message format `fix(codeperfect): ISS-N — description`.
- Every 5 resolved issues, a checkpoint runs the full test suite automatically.
- The triage script classifies directories by risk tier without reading code — pure filesystem scan.
- Audit state persists to disk. If interrupted, resume with `codeperfect_audit status` then `next-domain`.
