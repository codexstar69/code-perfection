---
name: code-perfection
description: "Autonomous code refactoring and optimization with enforced resolution loops, zero-regression verification, and large codebase audit strategy. Every change preserves behavior, introduces zero bugs, and loses zero functionality."
version: 2.0.0
---

# Code Perfection — Autonomous Refactoring Agent

Enforced code refactoring and optimization skill. Uses mechanical scripts to drive a resolution loop that cannot exit until all issues are resolved or explicitly deferred. The agent does not choose whether to follow the loop — the scripts drive execution.

## When to Activate

Use this skill when the user asks to:
- Refactor, optimize, or clean up code
- Audit a codebase for quality issues
- Fix multiple issues across files
- Run a code quality sweep
- Improve code without changing behavior
- Run verification checks on changes

**Trigger phrases:** "refactor", "optimize", "clean up", "code quality", "audit", "code perfection", "resolution loop", "fix all issues", "verify", "code sweep"

## Commands

| Command | Description |
|---------|-------------|
| `/code-perfection [path]` | Run the resolution loop on a target (default: cwd) |
| `/code-perfection:audit [path]` | Full tiered codebase audit (100+ files) |
| `/code-perfection:verify` | Run the 8-point verification checklist |

### Command Flags

| Flag | Available On | Effect |
|------|-------------|--------|
| `--scan-only` | code-perfection, audit | Report issues without fixing them |
| `--verify-only` | code-perfection | Run verify.sh only |
| `--resume` | code-perfection, audit | Resume from saved state |
| `--tier <level>` | audit | Filter domains by minimum tier |

## Architecture

All paths below are relative to `$SKILL_DIR` (the directory containing this file):

```
SKILL.md                    — this file (always loaded)
references/
  agents.md                 — core code standards (loaded into agent context)
  resolution-loop.md        — loop protocol + issue tracking
  audit.md                  — large codebase audit strategy
  parallel-vs-sequential.md — decision framework for parallel vs sequential
scripts/
  _lib.sh                   — shared library (colors, paths, helpers, atomic writes)
  verify.sh                 — 8-point verification checklist (exit 0/1)
  resolution-loop.sh        — issue ledger, lock, revert-on-failure, auto-commit
  audit-state.sh            — domain state management for large audits
  triage.sh                 — structural recon (discovers domains, classifies risk tiers)
```

## Loading Strategy

References are loaded on-demand to minimize context usage:

| Scenario | Load | Skip |
|----------|------|------|
| Simple fix (1-3 files) | `agents.md` | resolution-loop.md, audit.md |
| Multi-issue refactoring | `agents.md` + `resolution-loop.md` | audit.md |
| Codebase audit (100+ files) | `agents.md` + `audit.md` + `resolution-loop.md` | (all loaded) |
| Verify only | (none) | All references — script is self-contained |
| Choosing execution mode | `parallel-vs-sequential.md` | Load separately when needed |

**Lazy loading rule:** Do NOT read `parallel-vs-sequential.md` unless the agent is deciding between parallel and sequential execution for an audit. It is never needed for single-target refactoring.

## Adaptive Behavior

The skill scales from 1-file fixes to 1000-file audits:

| Target Size | Behavior |
|-------------|----------|
| 1-5 files | Read all files, identify all issues, run resolution loop |
| 6-30 files | Read in batches of 10, add issues incrementally |
| 31-99 files | Read in batches of 15, add issues incrementally |
| 100+ files | Auto-switch to audit mode (domain-scoped, tiered) |

## Execution

### For `/code-perfection <target>`

1. Read `$SKILL_DIR/references/agents.md` — the core code standards
2. Read `$SKILL_DIR/references/resolution-loop.md` — the loop protocol
3. Determine scope from `$ARGUMENTS`:
   - If a path is given, use it as the target
   - If empty, use the current working directory
4. Initialize the resolution loop:
   ```bash
   "$SKILL_DIR/scripts/resolution-loop.sh" init <target>
   ```
5. Scan the target for issues — read the code, identify problems using the rules in `agents.md`
6. For each issue found, add it to the ledger:
   ```bash
   "$SKILL_DIR/scripts/resolution-loop.sh" add "<file>" "<line>" "<severity>" "<description>"
   ```
7. Enter the resolution loop (see `references/resolution-loop.md` for the full protocol):
   - Pick highest-severity OPEN issue
   - `"$SKILL_DIR/scripts/resolution-loop.sh" start ISS-N`
   - Fix the issue (one atomic change)
   - `"$SKILL_DIR/scripts/verify.sh"` — verify the fix
   - If passed: `"$SKILL_DIR/scripts/resolution-loop.sh" resolve ISS-N`
   - If failed: `"$SKILL_DIR/scripts/resolution-loop.sh" fail ISS-N "<reason>"`
   - `"$SKILL_DIR/scripts/resolution-loop.sh" status` — exit code 1 = continue, 0 = done, 2 = max iterations
   - **NEVER ask "should I continue?" — the script decides.**
8. When done: `"$SKILL_DIR/scripts/resolution-loop.sh" report`

### For `/code-perfection:audit <target>`

1. Read `$SKILL_DIR/references/agents.md`
2. Read `$SKILL_DIR/references/audit.md`
3. Read `$SKILL_DIR/references/resolution-loop.md`
4. Run triage:
   ```bash
   "$SKILL_DIR/scripts/triage.sh" <target>
   "$SKILL_DIR/scripts/audit-state.sh" init <target>
   ```
5. Process domains in tier order (CRITICAL -> HIGH -> MEDIUM -> LOW):
   ```bash
   "$SKILL_DIR/scripts/audit-state.sh" next-domain
   "$SKILL_DIR/scripts/audit-state.sh" start-domain <name>
   # Run resolution loop on this domain
   "$SKILL_DIR/scripts/audit-state.sh" complete-domain <name>
   ```
6. After all domains: run boundary audit
7. Final report: `"$SKILL_DIR/scripts/audit-state.sh" report`

### For `/code-perfection:verify`

Simply run:
```bash
"$SKILL_DIR/scripts/verify.sh"
```

## Script Enforcement

The scripts enforce rules mechanically — agents cannot bypass them:

- **`verify.sh`** — auto-detects build system (TS/Rust/Go/Python/Elixir/Make), runs typecheck + tests + secret scan + dead code check. Exit 1 = change rejected.
- **`resolution-loop.sh`** — lockfile prevents concurrent writers, auto-reverts on failure, auto-defers after 3 attempts, auto-commits on resolve, checkpoint every 5 fixes. Exit code 0 = done, 1 = continue, 2 = max iterations exceeded.
- **`audit-state.sh`** — rejects `start-domain` if another domain is `in_progress`. Tracks per-domain issues/resolved/deferred. Resume-safe.
- **`triage.sh`** — classifies directories by risk tier (CRITICAL/HIGH/MEDIUM/LOW) without reading code. Pure filesystem scan.

## Requirements

- `python3` (required by `resolution-loop.sh`, `audit-state.sh`, and `triage.sh` for state management)
- `git` (required by `resolution-loop.sh` for revert-on-failure and auto-commit; `verify.sh` works without git but skips git-dependent checks)
- A build system (optional — `verify.sh` auto-detects and skips if missing)

## Error Handling

| Failure | Behavior |
|---------|----------|
| `python3` not found | `resolution-loop.sh`, `audit-state.sh`, `triage.sh` exit with clear error message; `verify.sh` is unaffected (pure bash) |
| `git` not found | `resolution-loop.sh` exits with clear error message; `verify.sh` skips git-dependent checks gracefully |
| No build system detected | `verify.sh` warns but passes (skips compile/test checks) |
| Lock held by another process | `resolution-loop.sh start` fails immediately |
| 3 failed fix attempts | Issue auto-deferred, loop continues with next issue |
| Max iterations exceeded | Loop exits with exit code 2 and summary report |
| Script missing or not executable | Agent stops and reports installation error with reinstall command |
| State file corrupted | Scripts use atomic writes (temp file + rename) to prevent corruption |
| Interrupted mid-loop | State persists on disk. Use `--resume` to continue. |

## Reinstallation

If scripts or references are missing:
```bash
# From the skill source directory:
./bin/code-perfection install

# Or install to a specific agent:
./bin/code-perfection install --agent claude-code
```
