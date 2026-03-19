# Parallel vs Sequential: Decision Framework

Not every audit task benefits from parallelism. Use the wrong mode and you waste effort, create conflicts, or miss cross-file bugs.

## decision tree

```
┌─────────────────────────────────────┐
│   Is this task modifying code?      │
│   (fixing, refactoring, writing)    │
└──────┬──────────────┬───────────────┘
    NO (read-only)    YES (writing)
       │                  │
       ▼                  ▼
┌──────────────┐   ALWAYS SEQUENTIAL
│ Are the work │   (one writer at a time)
│ units fully  │   enforced by fix.lock
│ independent? │   No exceptions.
│ (no shared   │
│  files, no   │
│  shared      │
│  imports)    │
└──┬────────┬──┘
   │YES     │NO
   ▼        ▼
PARALLEL  SEQUENTIAL
```

**The rules are binary. There is no "it depends."**

| Condition | Mode | Why |
|-----------|------|-----|
| Two agents reading independent domains | PARALLEL | No shared state, no conflicts |
| Two agents reading files that import each other | SEQUENTIAL | Cross-file context required |
| Any agent writing/fixing code | SEQUENTIAL | fix.lock enforces one writer |
| Boundary audit (reading from two domains) | SEQUENTIAL | Must see both sides simultaneously |
| Typecheck + lint + test suite | PARALLEL | Independent verification tasks |
| Triage of a new codebase | SEQUENTIAL | One triage, one domain map |

## when to audit sequentially

Sequential is the default. Use it when:

- **Files are interdependent.** If file A's correctness depends on understanding file B (shared types, call chains, middleware stacks), they must be audited in the same pass.
- **The domain is small.** Under 40 files, the overhead of splitting and merging exceeds the time saved.
- **Cross-file bugs are likely.** Contract mismatches, error propagation gaps, and state management bugs require reading multiple files with full context.
- **You are fixing, not just scanning.** Fixes modify files. Two parallel agents modifying files in the same directory will conflict. Fixing is always sequential — one writer at a time.
- **The boundary audit phase.** Boundary pairs must read files from both domains simultaneously. This is inherently sequential per pair.

## when to audit in parallel

Parallel scanning is safe ONLY when ALL of these are true:

1. The task is **read-only** (scanning, not fixing)
2. The work units are **fully independent** (no shared files, no shared imports)
3. Each agent writes to its **own output file** (never the same file)

Safe parallel scenarios:
- Two agents scanning independent domains (auth vs billing)
- Parallel verification tasks (typecheck, lint, tests)
- Two skeptics challenging findings in separate directories

## the hybrid pattern (recommended for medium-to-large codebases)

```
Phase 1: Parallel read-only triage
  → Two agents scan the same files with different lenses (security, logic)
  → Produces a combined shortlist of suspicious areas
  → Enforced: both agents write to separate output files, never modify source
  → Output: <agent-id>-findings.json per agent

Phase 2: Sequential deep audit
  → One agent reads every file in risk-map order
  → Uses triage hints to prioritize but scans ALL files
  → Produces the authoritative issue list in .codeperfect/issues.json

Phase 3: Parallel challenge (ONLY if findings split cleanly by directory)
  → Skeptic A challenges findings in service/auth
  → Skeptic B challenges findings in service/billing
  → Merge results: scripts/audit-state.sh merge-findings
  → IF findings do NOT split cleanly → use SEQUENTIAL challenge instead

Phase 4: Sequential resolution loop
  → One agent fixes issues one at a time via scripts/resolution-loop.sh
  → Commits after each fix, reverts on failure
  → NEVER two writers in the same codebase
```

## parallel safety rules

These are enforced by the scripts, not by agent discipline:

- **Read-only agents may run in parallel.** They read files and produce reports. They never modify code. The `scripts/audit-state.sh` script rejects `start-domain` calls from two agents on the same domain.
- **Writing agents must be sequential.** One writer at a time. `scripts/resolution-loop.sh` uses an atomic lock directory (`.codeperfect/fix.lock/`, created via `mkdir` for race-condition safety) — a second `start` call fails immediately if an issue is already in_progress.
- **Never merge parallel findings blindly.** After parallel scanning, deduplicate by file + line. If two agents report different issues on the same line, a sequential tiebreaker pass reads the code and decides.
- **Parallel agents must not share state.** Each agent writes to its own output file (`<agent-id>-findings.json`). Merging happens after all agents complete via `scripts/audit-state.sh merge-findings`.
- **If a parallel agent fails, the work is not lost.** The successful agent's results stand. Re-run only the failed agent's scope.

## what NOT to do

- Do NOT run two resolution loops in parallel. The lock will reject the second.
- Do NOT have two agents scan the same domain in parallel (they will produce conflicting issue IDs).
- Do NOT merge findings without deduplication (`merge-findings` handles this automatically).
- Do NOT start parallel work if you are unsure whether files are independent. When in doubt, go sequential. The cost of a false parallel is wasted work or missed bugs. The cost of false sequential is only slower speed.
