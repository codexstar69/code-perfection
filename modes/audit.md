# Large Codebase Audit Strategy

Auditing a large codebase (100+ files) requires a systematic approach to avoid losing context, missing issues, or wasting effort re-reading code. The strategy is domain-first, tiered, and state-driven.

**Enforcement:** Run the audit via `scripts/audit-state.sh`. The script manages domain state, tracks coverage, and prevents re-scanning completed domains.

## why naive approaches fail at scale

- **Flat file-by-file scanning** loses domain context. Reading `auth/login.ts` then `billing/invoice.ts` in the same pass means you understand neither domain deeply.
- **Reading everything at once** overflows working memory. By file 40 you have forgotten file 5.
- **Random sampling** misses the most dangerous bugs — those at domain boundaries where assumptions change between services.

## decision tree: how to start

```
Is this a new audit (no .codeperfect/audit-state.json)?
├── YES → Run `scripts/triage.sh <target>` then `scripts/audit-state.sh init <target>`
└── NO  → Run `scripts/audit-state.sh status` to see progress
          └── Any domain in_progress? → Resume it (do NOT start a new one)
          └── All domains done? → Run `scripts/audit-state.sh find-boundaries <target>`
              └── All boundaries done? → Run `scripts/audit-state.sh report`
              └── Boundaries pending? → Start next boundary
          └── Domains pending? → Run `scripts/audit-state.sh next-domain`
```

## tier 0: rapid structural recon

Run `scripts/triage.sh <target-dir>` before reading any code. The script:

1. **Discovers domains** — lists top-level directories (using `os.scandir` for speed on large trees).
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

**Scalability note:** Handles 10,000+ files. File lists are capped at 500 per domain and 2,000 total in scan_order. The script uses `os.scandir()` instead of `os.walk()` for faster directory traversal.

## tier 1: domain-scoped deep audits

Process ONE domain at a time. The full pipeline runs within each domain before moving to the next.

```bash
# Get the next domain (respects tier priority: critical > high > medium > low)
scripts/audit-state.sh next-domain

# Mark domain as in-progress
scripts/audit-state.sh start-domain auth

# Agent reads ALL files in this domain, identifies issues, records them:
scripts/resolution-loop.sh init src/auth/
scripts/resolution-loop.sh scan src/auth/

# Resolution loop runs until domain issues are all DONE/DEFERRED
# (see resolution-loop.md for the exact protocol)

# Mark domain as complete
scripts/audit-state.sh complete-domain auth
```

### decision tree: within a domain

```
Starting domain audit:
  1. Call `start-domain <name>`
  2. Call `resolution-loop.sh init <domain-path>`
  3. Read ALL files in domain → call `add` or `add-batch` for each issue
  4. Enter resolution loop (see resolution-loop.md)
  5. When resolution loop exits (status returns 0):
     └── Call `complete-domain <name>`
     └── Call `next-domain`
         ├── Output starts with "NEXT:" → go to step 1 with new domain
         ├── Output is "ALL_DOMAINS_DONE" → proceed to tier 2 (boundaries)
         └── Output starts with "RESUME:" → ERROR: should not happen after complete
```

**Why one domain at a time:** The agent maintains full context for the entire domain — middleware, models, routes, utils — in one coherent pass. Issues that span multiple files within the domain are visible.

**If a domain exceeds working memory capacity:**
- Chunk within the domain boundary. Split by subdirectory or logical grouping.
- Never chunk across domains — that destroys coherence.
- Process chunks sequentially within the domain. After all chunks, do a cross-chunk consistency check.

**If a domain has 500+ files:**
- Split into sub-domains by subdirectory.
- Process each sub-domain as a mini-audit within the parent domain.
- Do NOT call `complete-domain` until all sub-domains are done.

## tier 2: cross-domain boundary audit

After all individual domains are audited, run a focused pass on service boundaries.

```bash
# Discover boundary files (files that import from other domains)
scripts/audit-state.sh find-boundaries src/
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

### decision tree: boundaries

```
After find-boundaries:
  └── 0 boundaries found? → Skip to tier 3 (report)
  └── N boundaries found? → For each pending boundary:
      1. Call `start-boundary <pair>`
      2. Read ALL files listed in the boundary
      3. Log issues via resolution-loop.sh add
      4. Run resolution loop to fix
      5. Call `complete-boundary <pair>`
      6. Repeat for next pending boundary
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

**Corruption recovery:** All state writes create a `.bak` backup before overwriting. If `audit-state.json` is corrupted (invalid JSON), the script auto-recovers from the backup.

## context preservation tactics

Large audits risk losing context as the agent's working memory fills. The system mitigates this:

- **Write findings to disk between phases.** The resolution loop script persists everything to `.codeperfect/issues.json`. The agent reads from disk at the start of each phase — not from memory.
- **One domain at a time.** Finish domain A completely before starting domain B. The script enforces this — `start-domain` fails if another domain is `in_progress`.
- **Checkpoint after each domain.** The script runs the full test suite when a domain completes. If new failures appear, it blocks the next domain until they are resolved.
- **If earlier files are becoming hazy, stop expanding.** Finish the current file thoroughly rather than skimming more. Partial coverage with high confidence beats full coverage with low confidence.
- **Persist the triage.** `scripts/triage.sh` runs once and writes `.codeperfect/triage.json`. Subsequent iterations read it from disk.
- **The audit state file is the single source of truth.** Not memory. Not git log. The state file says what is done, what remains, and where to resume.

## what NOT to do

- Do NOT start two domains at once. The script blocks this.
- Do NOT edit `audit-state.json` or `issues.json` directly. Use the scripts.
- Do NOT skip triage. Always run `triage.sh` first.
- Do NOT re-audit a `done` domain unless explicitly asked.
- Do NOT read code during triage. Triage is structural only — file counts, directories, tier classification.
- Do NOT fix issues during the scan phase. Scan first (collect all issues), then fix (resolution loop).
