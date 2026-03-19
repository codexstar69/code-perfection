# Code Perfection — System Architecture

Portable reference for integrating this system into any autonomous agent, CI/CD pipeline, or coding tool.

## What This System Does

An enforced resolution loop for autonomous code refactoring. The agent scans code, identifies issues, fixes them one at a time, verifies each fix, and cannot exit until all issues are resolved or explicitly deferred. Scripts enforce the rules — the agent follows.

## Core Concept: The Agent Doesn't Decide — The Script Decides

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│    AGENT      │────▶│   SCRIPTS    │────▶│    STATE     │
│  (any LLM)   │◀────│  (enforce)   │◀────│   (.json)    │
└──────────────┘     └──────────────┘     └──────────────┘
  reads code           drives loop          persists to disk
  edits code           reverts on fail      survives restarts
  picks issues         auto-commits         single source of truth
                       auto-defers
                       blocks exit
```

The agent's job: read code, pick an issue, fix it, call the script.
The script's job: verify, commit, revert, track, block, report.

## File System

```
scripts/
  _lib.sh                  shared constants, colors, pure-bash JSON helpers
  verify.sh                8-point verification checklist (exit 0 = pass)
  resolution-loop.sh       issue ledger + fix-verify-decide enforcement
  audit-state.sh           domain-scoped audit state for large codebases
  triage.sh                structural recon (risk-tier classification)

modes/                     (documentation for agents — load on demand)
  resolution-loop.md       loop protocol with decision trees
  audit.md                 tiered audit strategy
  parallel-vs-sequential.md  when to parallelize

agents.md                  core code standards (always loaded)

.codeperfect/              (runtime state — gitignored, never committed)
  issues.json              issue ledger
  audit-state.json         domain audit progress
  triage.json              structural recon results
  fix.lock/                atomic lock directory
  iteration.count          loop iteration counter
  *.bak                    automatic backups for corruption recovery
```

## Dependencies

| Dependency | Required By | Fallback If Missing |
|------------|-------------|---------------------|
| `bash` 4+ | all scripts | none (required) |
| `python3` | resolution-loop.sh, audit-state.sh, triage.sh | scripts exit with error |
| `git` | resolution-loop.sh (revert + commit) | script exits with error |
| `grep`, `sed` | verify.sh | standard POSIX — always available |

No npm, no node, no external packages. Pure bash + python3 standard library.

## The Resolution Loop

### Flow

```
INIT ──▶ SCAN ──▶ PICK highest-severity OPEN issue
                         │
                         ▼
                  ┌─── START (acquires lock)
                  │      │
                  │      ▼
                  │   FIX (agent edits code)
                  │      │
                  │      ▼
                  │   VERIFY (scripts/verify.sh)
                  │      │
                  │   ┌──┴──┐
                  │   │     │
                  │  PASS  FAIL
                  │   │     │
                  │   ▼     ▼
                  │ RESOLVE FAIL (auto-revert, increment attempt)
                  │ (commit)  │
                  │   │       │ attempt < 3? ──▶ requeue as OPEN
                  │   │       │ attempt = 3? ──▶ mark DEFERRED
                  │   │       │
                  │   ▼       ▼
                  │   STATUS ◀┘
                  │     │
                  │  exit=1 ──▶ loop continues (back to PICK)
                  │  exit=0 ──▶ all done
                  │  exit=2 ──▶ max iterations hit
                  │     │
                  │     ▼
                  └── REPORT
```

### Commands (resolution-loop.sh)

| Command | Args | What It Does | Exit Code |
|---------|------|-------------|-----------|
| `init` | `[target]` | Create empty issue ledger | 0 |
| `scan` | `[target]` | Prompt agent to populate ledger | 0 |
| `add` | `file line severity description` | Add one issue (OPEN) | 0 |
| `add-batch` | (reads stdin: `file\|line\|sev\|desc`) | Add N issues in one call | 0 |
| `start` | `ISS-N` | Mark in-progress, acquire lock | 0/1 |
| `resolve` | `ISS-N` | Mark done, auto-commit, release lock | 0 |
| `fail` | `ISS-N reason` | Auto-revert, increment attempt, release lock | 0 |
| `status` | — | Show progress | 0=done, 1=continue, 2=max |
| `report` | — | Generate markdown report | 0 |

### Issue States

```
OPEN ──▶ IN_PROGRESS ──▶ DONE
                     ──▶ DEFERRED (after 3 failed attempts)
                     ──▶ OPEN (requeued after revert)
```

### Safety Guarantees

| Guarantee | How Enforced |
|-----------|-------------|
| No concurrent writers | Atomic `mkdir`-based lock |
| Auto-revert on failure | `git checkout -- ':!.codeperfect'` (preserves state dir) |
| Auto-defer after 3 fails | Script blocks further attempts |
| Auto-commit on resolve | `git commit -F -` (safe for special chars) |
| No state corruption | Atomic write (temp file + `os.replace` + `fsync`) |
| Corruption recovery | `.bak` backup before every write, auto-fallback |
| Max iteration cap | `max(10, issue_count * 3)` — hard exit |
| Checkpoint every 5 fixes | Full test suite, not just changed files |

## The 8-Point Verification Checklist (verify.sh)

```
1. COMPILES     auto-detects: tsc, cargo, go, mypy, mix, make, cmake
2. TESTS PASS   auto-detects: bun test, npm test, cargo test, go test, pytest, mix test
3. NO NEW any   grep-based scan of changed .ts/.tsx files
4. NO SECRETS   pattern match for passwords, API keys, tokens in diff
5. NO DEAD CODE grep-based unused import detection
6. NO SCOPE CREEP  warn >10 files, fail >20 files
7. NAMING       (agent responsibility — not mechanically enforceable)
8. BEHAVIOR     (agent responsibility — not mechanically enforceable)

Exit 0 = all mechanical checks pass
Exit 1 = at least one check failed (details in output)
```

### Build System Auto-Detection

| File Exists | Compile Check | Test Check |
|-------------|--------------|------------|
| `package.json` | `bun run typecheck` or `npx tsc --noEmit` | `bun run test` or `npm test` |
| `Cargo.toml` | `cargo check` | `cargo test` |
| `go.mod` | `go build ./...` | `go test ./...` |
| `pyproject.toml` / `setup.py` | `mypy .` | `pytest` |
| `mix.exs` | `mix compile --warnings-as-errors` | `mix test` |
| `CMakeLists.txt` | `cmake --build build` | `ctest --test-dir build` |
| `Makefile` | `make` | `make test` |
| none | skip (warn) | skip (warn) |

## Large Codebase Audit (100+ files)

### Tiered Strategy

```
Tier 0: TRIAGE (no code reading)
  └─ scripts/triage.sh discovers domains, classifies risk tiers
  └─ writes .codeperfect/triage.json

Tier 1: DOMAIN AUDITS (one at a time)
  └─ CRITICAL domains first → HIGH → MEDIUM → LOW
  └─ full resolution loop per domain
  └─ scripts/audit-state.sh enforces one-domain-at-a-time

Tier 2: BOUNDARY AUDIT (cross-domain)
  └─ scripts/audit-state.sh find-boundaries
  └─ checks trust violations, contract mismatches, race conditions

Tier 3: MERGE + REPORT
  └─ scripts/audit-state.sh report
  └─ deduplicates, produces final report
```

### Domain Risk Classification

| Tier | Pattern Matches | Examples |
|------|----------------|---------|
| CRITICAL | auth, payment, security, gateway, middleware, crypto, token, session | `src/auth/`, `lib/payments/` |
| HIGH | api, service, controller, handler, model, database, store, queue | `src/api/`, `models/` |
| MEDIUM | util, helper, format, component | `src/utils/`, `components/` |
| LOW | test, fixture, mock, script, doc, migration, config | `tests/`, `scripts/` |

### Audit State

```json
{
  "domains": {
    "auth":    { "status": "done",        "issues_found": 12, "issues_resolved": 11 },
    "billing": { "status": "in_progress", "issues_found": 5,  "issues_resolved": 2  },
    "orders":  { "status": "pending" }
  },
  "boundaries": {
    "auth-billing": { "status": "pending" }
  }
}
```

Resume-safe: on restart, skip `done` domains, resume from `in_progress` or first `pending`.

## Parallel vs Sequential

```
                    ┌─────────────────────┐
                    │   Is it read-only?   │
                    └──────┬──────┬────────┘
                       YES │      │ NO (fixing)
                           │      │
              ┌────────────▼──┐   └──────────────────┐
              │ Are the scopes │                       │
              │ independent?   │                       ▼
              └──┬─────────┬──┘               ALWAYS SEQUENTIAL
                 │YES      │NO                (one writer at a time)
                 │         │                  enforced by fix.lock
                 ▼         ▼
            PARALLEL    SEQUENTIAL
```

| Condition | Mode | Why |
|-----------|------|-----|
| Scanning independent domains | Parallel | No shared files |
| Scanning interdependent files | Sequential | Need cross-file context |
| Fixing anything | Sequential | One writer, atomic commits |
| Running typecheck + lint + test | Parallel | Independent processes |
| Boundary audit | Sequential per pair | Need both domains in context |

## Performance Characteristics

| Operation | Method | Speed |
|-----------|--------|-------|
| `next_id` | Pure bash (grep + awk) | ~2ms (was ~94ms with python3) |
| `count_issues` | Pure bash | ~2ms (was ~60ms with python3) |
| `has_status` | Pure bash | ~2ms (was ~60ms with python3) |
| `add` (single) | python3 | ~50ms |
| `add-batch` (N issues) | python3 (1 invocation) | ~50ms total |
| `verify.sh` (no build system) | pure bash | ~50ms |
| `verify.sh` (with typecheck) | depends on project | 1-30s |
| `triage.sh` (1000 files) | python3 + os.scandir | <2s |
| `triage.sh` (10000 files) | python3 + os.scandir | <10s |

## Integration Guide

### Minimal Integration (any system)

```bash
# 1. Initialize
scripts/resolution-loop.sh init src/

# 2. Add issues (your scanner populates these)
scripts/resolution-loop.sh add "src/auth.ts" "45" "critical" "SQL injection"
scripts/resolution-loop.sh add "src/utils.ts" "12" "low" "Dead code"

# 3. Loop until done
while true; do
  # Your agent picks an issue and fixes it
  scripts/resolution-loop.sh start ISS-1

  # Your agent edits the code...

  # Verify
  if scripts/verify.sh; then
    scripts/resolution-loop.sh resolve ISS-1
  else
    scripts/resolution-loop.sh fail ISS-1 "tests broke"
  fi

  # Check if done
  scripts/resolution-loop.sh status && break
done

# 4. Report
scripts/resolution-loop.sh report
```

### CI/CD Integration

```yaml
# GitHub Actions example
- name: Code Perfection Audit
  run: |
    scripts/triage.sh src/
    scripts/audit-state.sh init src/
    # Your agent or script processes each domain...
    scripts/audit-state.sh report

- name: Verify Changes
  run: scripts/verify.sh
```

### LLM Agent Integration

Give the agent these tools:
1. A way to call `scripts/resolution-loop.sh <command> <args>`
2. A way to call `scripts/verify.sh`
3. A way to read/edit source files
4. The content of `agents.md` (code standards)
5. The content of `modes/resolution-loop.md` (loop protocol)

The agent needs NO other context. The scripts handle everything else.

### Platform Support

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS (zsh) | Yes | Primary development platform |
| Linux (bash) | Yes | Tested with bash 4+ |
| WSL | Yes | Same as Linux |
| Windows (native) | No | Requires bash (use WSL or Git Bash) |
| Docker | Yes | Any image with bash + python3 + git |
| CI/CD runners | Yes | GitHub Actions, GitLab CI, CircleCI |

### Agent Platforms with Pre-Built Integrations

| Platform | Integration | Install |
|----------|------------|---------|
| Claude Code | Skill + Commands | `node skill/bin/code-perfection install --agent claude-code` |
| Codex | Skill + Commands | `node skill/bin/code-perfection install --agent codex` |
| Pi (pi.dev) | TypeScript Extension + Tools + Commands | `pi install ./pi-extension` |
| Cursor | Skill + Commands | `node skill/bin/code-perfection install --agent cursor` |
| Kiro | Skill + Commands | `node skill/bin/code-perfection install --agent kiro` |
| Any other agent | Shell scripts directly | See "Minimal Integration" above |

## State File Schemas

### issues.json

```json
{
  "version": 1,
  "created": "ISO-8601",
  "target": "src/",
  "issues": [
    {
      "id": "ISS-1",
      "file": "src/auth.ts",
      "line": 45,
      "severity": "critical|high|medium|low",
      "description": "string",
      "status": "open|in_progress|done|deferred",
      "attempts": 0,
      "history": [
        { "attempt": 1, "action": "resolved|failed|auto-deferred", "reason": "string", "timestamp": "ISO-8601" }
      ]
    }
  ]
}
```

### triage.json

```json
{
  "version": 1,
  "target": "src/",
  "total_files": 342,
  "domain_count": 8,
  "domains": [
    { "name": "auth", "path": "src/auth", "tier": "critical", "file_count": 42 }
  ],
  "scan_order": ["src/auth/login.ts", "src/auth/middleware.ts", "..."],
  "tier_summary": { "critical": 2, "high": 3, "medium": 2, "low": 1 }
}
```

### audit-state.json

```json
{
  "version": 1,
  "target": "src/",
  "domains": {
    "auth": { "status": "done|in_progress|pending", "tier": "critical", "file_count": 42, "issues_found": 12, "issues_resolved": 11, "issues_deferred": 1 }
  },
  "boundaries": {
    "auth-billing": { "status": "done|in_progress|pending", "files": ["src/auth/billing-guard.ts"] }
  },
  "total_resolved": 11,
  "total_deferred": 1
}
```

## License

MIT
