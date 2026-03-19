# Parallel vs Sequential: Decision Framework

Not every audit task benefits from parallelism. Use the wrong mode and you waste effort, create conflicts, or miss cross-file bugs.

## when to audit sequentially

Sequential is the default. Use it when:

- **Files are interdependent.** If file A's correctness depends on understanding file B (shared types, call chains, middleware stacks), they must be audited in the same pass.
- **The domain is small.** Under 40 files, the overhead of splitting and merging exceeds the time saved.
- **Cross-file bugs are likely.** Contract mismatches, error propagation gaps, and state management bugs require reading multiple files with full context. Parallel agents miss these.
- **You are fixing, not just scanning.** Fixes modify files. Two parallel agents modifying files in the same directory will conflict. Fixing is always sequential — one writer at a time.
- **The boundary audit phase.** Boundary pairs must read files from both domains simultaneously. This is inherently sequential per pair.

## when to audit in parallel

Parallel scanning is safe when the work units are independent and read-only:

- **Multiple independent domains.** Domain `auth` and domain `billing` have no shared files. Two agents can scan them simultaneously, each maintaining full context of their own domain.
- **Read-only triage passes.** A quick parallel sweep with two "lenses" (security lens + logic lens) over the same files can surface hints faster. But the results are not final — they feed into a sequential deep scan.
- **Skeptic/challenger on independent finding sets.** If findings fall cleanly into separate directories, two Skeptics can challenge their own subsets in parallel.
- **Independent verification tasks.** Typecheck, lint, and test suite runs are naturally parallel.

## the hybrid pattern (recommended for medium-to-large codebases)

```
Phase 1: Parallel read-only triage
  → Two agents scan the same files with different lenses (security, logic)
  → Produces a combined shortlist of suspicious areas
  → Enforced: both agents write to separate output files, never modify source

Phase 2: Sequential deep audit
  → One agent reads every file in risk-map order
  → Uses triage hints to prioritize but scans ALL files
  → Produces the authoritative issue list in .codeperfect/issues.json

Phase 3: Parallel challenge (if findings split cleanly by directory)
  → Skeptic A challenges findings in service/auth
  → Skeptic B challenges findings in service/billing
  → Merge results after both complete

Phase 4: Sequential resolution loop
  → One agent fixes issues one at a time via scripts/resolution-loop.sh
  → Commits after each fix, reverts on failure
  → Never two writers in the same codebase
```

## parallel safety rules

These are enforced by the scripts, not by agent discipline:

- **Read-only agents may run in parallel.** They read files and produce reports. They never modify code. The `scripts/audit-state.sh` script rejects `start-domain` calls from two agents on the same domain.
- **Writing agents must be sequential.** One writer at a time. `scripts/resolution-loop.sh` uses a lockfile (`.codeperfect/fix.lock`) — a second instance fails immediately with "lock held."
- **Never merge parallel findings blindly.** After parallel scanning, deduplicate by file + line. If two agents report different issues on the same line, a sequential tiebreaker pass reads the code and decides.
- **Parallel agents must not share state.** Each agent writes to its own output file (`<agent-id>-findings.json`). Merging happens after all agents complete via `scripts/audit-state.sh merge-findings`.
- **If a parallel agent fails, the work is not lost.** The successful agent's results stand. Re-run only the failed agent's scope.

## decision summary

```
                    ┌─────────────────────┐
                    │   Is it read-only?   │
                    └──────┬──────┬────────┘
                       YES │      │ NO (writing/fixing)
                           │      │
              ┌────────────▼──┐   └──────────────────┐
              │ Are the scopes │                       │
              │ independent?   │                       ▼
              └──┬─────────┬──┘               ALWAYS SEQUENTIAL
                 │YES      │NO                (one writer at a time)
                 │         │                  enforced by fix.lock
                 ▼         ▼
            PARALLEL    SEQUENTIAL
          (safe — no   (must maintain
          shared state) cross-file context)
```
