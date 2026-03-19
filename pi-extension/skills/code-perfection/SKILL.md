---
name: code-perfection
description: "Autonomous code refactoring and optimization with enforced resolution loops. Uses mechanical scripts for zero-regression verification, auto-revert on failure, and large codebase auditing with domain-scoped tiered scanning. Every change preserves behavior, introduces zero bugs, and loses zero functionality."
---

# Code Perfection — Autonomous Refactoring Agent

Use this skill when the user asks to refactor, optimize, clean up, or audit code for quality issues. The skill provides enforced resolution loops that cannot exit until all issues are resolved or explicitly deferred.

## Tools Provided

| Tool | Purpose |
|------|---------|
| `codeperfect_verify` | 8-point verification checklist (compiles, tests, no any, no secrets, no dead code, no scope creep) |
| `codeperfect_loop` | Resolution loop — issue ledger, lock, revert-on-failure, auto-commit, auto-defer |
| `codeperfect_audit` | Domain-scoped audit state — triage, one-domain-at-a-time, boundary analysis |
| `codeperfect_triage` | Structural recon — risk-tier classification without reading code |

## Commands

| Command | Description |
|---------|-------------|
| `/code-perfection <path>` | Run the resolution loop on a target |
| `/code-perfection:audit <path>` | Full tiered codebase audit |
| `/code-perfection:verify` | Run verification checklist |

## Code Standards

Read `references/agents.md` for the full code standards the agent must follow during refactoring.

## Resolution Loop Protocol

Read `references/resolution-loop.md` for the loop protocol: SCAN → PLAN → FIX → VERIFY → DECIDE → PROGRESS CHECK.

## Audit Strategy

Read `references/audit.md` for the tiered audit approach: Tier 0 (triage) → Tier 1 (domain audits) → Tier 2 (boundary audits) → Tier 3 (merge & report).

## Parallel vs Sequential

Read `references/parallel-vs-sequential.md` for when to use parallel vs sequential scanning.
