# Large Codebase Audit Strategy

Auditing a large codebase (100+ files) requires a systematic approach to avoid losing context, missing issues, or wasting effort re-reading code. The strategy is domain-first, tiered, and state-driven.

**Enforcement:** Run the audit via `scripts/audit-state.sh`. The script manages domain state, tracks coverage, and prevents re-scanning completed domains.

## why naive approaches fail at scale

- **Flat file-by-file scanning** loses domain context. Reading `auth/login.ts` then `billing/invoice.ts` in the same pass means you understand neither domain deeply.
- **Reading everything at once** overflows working memory. By file 40 you have forgotten file 5.
- **Random sampling** misses the most dangerous bugs — those at domain boundaries where assumptions change between services.

## tier 0: rapid structural recon

Run `scripts/triage.sh <target-dir>` before reading any code. The script:

1. **Discovers domains** — lists top-level directories (2 levels deep).
2. **Counts source files per domain** — filters out non-source files automatically.
3. **Classifies domains by risk tier:**

| Tier | Domains | Why |
|------|---------|-----|
| CRITICAL | auth, payments, security, API gateways, middleware | Direct attack surface, data integrity |
| HIGH | core business logic, database models, state management | Behavioral correctness, data flow |
| MEDIUM | utilities, helpers, formatting, UI components | Lower blast radius |
| LOW | config, scripts, migrations, static assets | Rarely contain behavioral bugs |

4. **Writes the domain map** to `.codeperfect/triage.json`. This persists across iterations.

```bash
scripts/triage.sh src/
# Output: .codeperfect/triage.json with domain map, file counts, risk tiers
```

## tier 1: domain-scoped deep audits

Process ONE domain at a time. The full pipeline runs within each domain before moving to the next.

```bash
# Mark domain as in-progress
scripts/audit-state.sh start-domain auth

# Agent reads ALL files in this domain, identifies issues, records them:
scripts/resolution-loop.sh init src/auth/
scripts/resolution-loop.sh scan src/auth/

# Resolution loop runs until domain issues are all DONE/DEFERRED
# (see references/resolution-loop.md)

# Mark domain as complete
scripts/audit-state.sh complete-domain auth
```

**Why one domain at a time:** The agent maintains full context for the entire domain — middleware, models, routes, utils — in one coherent pass. Issues that span multiple files within the domain are visible.

**If a domain exceeds working memory capacity:**
- Chunk within the domain boundary. Split by subdirectory or logical grouping.
- Never chunk across domains — that destroys coherence.
- Process chunks sequentially within the domain. After all chunks, do a cross-chunk consistency check.

## tier 2: cross-domain boundary audit

After all individual domains are audited, run a focused pass on service boundaries.

```bash
# Discover boundary files (files that import from other domains)
scripts/audit-state.sh find-boundaries src/

# Output: boundaries stored in .codeperfect/audit-state.json under "boundaries" key
```

For each boundary pair, read files from BOTH domains simultaneously and check for:
- **Trust boundary violations** — does domain A trust unvalidated data from domain B?
- **Contract mismatches** — does the caller assume a return type the callee doesn't guarantee?
- **Race conditions** across domain boundaries.
- **Auth/permission gaps** — is a function reachable from both protected and unprotected routes?
- **Partial failure states** — multi-step cross-domain operations where step 2 fails but step 1's side effects aren't rolled back.

```bash
scripts/audit-state.sh start-boundary auth-billing
# Agent audits boundary files...
scripts/audit-state.sh complete-boundary auth-billing
```

## tier 3: merge, deduplicate, report

```bash
scripts/audit-state.sh report
# Merges all domain issue ledgers
# Deduplicates by file + line + description
# Produces .codeperfect/audit-report.md
```

## audit state management

The script persists progress to `.codeperfect/audit-state.json`:

```json
{
  "version": 1,
  "target": "src/",
  "created": "2026-03-19T10:00:00Z",
  "triage": ".codeperfect/triage.json",
  "domains": {
    "auth": { "status": "done", "issues_found": 12, "issues_resolved": 11, "issues_deferred": 1 },
    "billing": { "status": "in_progress", "issues_found": 5, "issues_resolved": 2 },
    "orders": { "status": "pending" }
  },
  "boundaries": {
    "auth-billing": { "status": "pending" },
    "auth-api-gateway": { "status": "pending" }
  },
  "total_resolved": 13,
  "total_deferred": 1,
  "last_updated": "2026-03-19T10:30:00Z"
}
```

**Resume rule:** On restart, the script reads state and skips `done` domains. It resumes from the first `in_progress` or `pending` domain. It never re-audits `done` domains unless `--force` is passed.

## usage

```bash
# Full audit workflow
scripts/triage.sh src/                          # Tier 0: structural recon
scripts/audit-state.sh init src/                # Initialize audit state from triage
scripts/audit-state.sh next-domain              # Get the next domain to audit
scripts/audit-state.sh start-domain <name>      # Mark domain in-progress
# ... run resolution loop on this domain ...
scripts/audit-state.sh complete-domain <name>   # Mark domain done
scripts/audit-state.sh next-domain              # Get next domain (or "all done")
scripts/audit-state.sh find-boundaries src/     # Tier 2: discover boundaries
scripts/audit-state.sh start-boundary <pair>    # Audit boundary pair
scripts/audit-state.sh complete-boundary <pair> # Mark boundary done
scripts/audit-state.sh report                   # Tier 3: final report

# Resume after interruption
scripts/audit-state.sh status                   # Show current progress
scripts/audit-state.sh next-domain              # Picks up where you left off
```

## context preservation tactics

Large audits risk losing context as the agent's working memory fills. The system mitigates this:

- **Write findings to disk between phases.** The resolution loop script persists everything to `.codeperfect/issues.json`. The agent reads from disk at the start of each phase — not from memory.
- **One domain at a time.** Finish domain A completely before starting domain B. The script enforces this — `start-domain` fails if another domain is `in_progress`.
- **Checkpoint after each domain.** The script runs the full test suite when a domain completes. If new failures appear, it blocks the next domain until they are resolved.
- **If earlier files are becoming hazy, stop expanding.** Finish the current file thoroughly rather than skimming more. Partial coverage with high confidence beats full coverage with low confidence. The loop will cover the rest in the next domain.
- **Persist the triage.** `scripts/triage.sh` runs once and writes `.codeperfect/triage.json`. Subsequent iterations read it from disk.
- **The audit state file is the single source of truth.** Not memory. Not git log. The state file says what is done, what remains, and where to resume.
