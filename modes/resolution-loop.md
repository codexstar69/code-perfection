# Resolution Loop

Every multi-issue refactoring task runs inside a resolution loop. The loop does not exit until all issues are resolved or explicitly deferred. No partial work. No "good enough." Fix it or explain why it cannot be fixed.

**Enforcement:** Run the loop via `scripts/resolution-loop.sh`. The script manages the issue ledger, drives iteration, enforces revert-on-failure, and blocks exit until the ledger is clean.

## loop protocol

The script enforces this exact flow:

```
ITERATION = 0

1. SCAN    — identify all issues in scope
   → scripts/resolution-loop.sh scan <target-dir>
   → populates .codeperfect/issues.json with status=OPEN

2. PLAN    — rank issues by severity, group by file/module
   → agent reads .codeperfect/issues.json, picks highest-severity OPEN issue

3. FIX     — apply ONE atomic change (single concern)
   → agent edits code

4. VERIFY  — run verification checklist
   → scripts/verify.sh
   → exit code 0 = pass, non-zero = fail

5. DECIDE  — the script handles this, not the agent:
   IF verify passes:
       scripts/resolution-loop.sh resolve <issue-id>
       → marks DONE, commits automatically
   IF verify fails:
       scripts/resolution-loop.sh fail <issue-id> "<reason>"
       → reverts ALL uncommitted changes via git checkout
       → increments attempt counter
       → if 3 attempts: marks DEFERRED automatically
   IF new issue discovered during fix:
       scripts/resolution-loop.sh add "<file>" "<line>" "<severity>" "<description>"
       → adds new OPEN issue to the ledger

6. PROGRESS CHECK  — the script handles this:
   → scripts/resolution-loop.sh status
   → prints remaining OPEN/IN_PROGRESS count
   → returns exit code 0 if done (all DONE or DEFERRED)
   → returns exit code 1 if issues remain
   → agent MUST continue if exit code is 1
   → NEVER ask "should I continue?" — the script decides
```

## issue ledger format

The script manages `.codeperfect/issues.json`:

```json
{
  "version": 1,
  "created": "2026-03-19T10:00:00Z",
  "issues": [
    {
      "id": "ISS-1",
      "file": "src/auth/login.ts",
      "line": 45,
      "severity": "critical",
      "description": "SQL injection via unsanitized query parameter",
      "status": "open",
      "attempts": 0,
      "history": []
    },
    {
      "id": "ISS-2",
      "file": "src/utils/format.ts",
      "line": 12,
      "severity": "medium",
      "description": "Dead code — function never called",
      "status": "done",
      "attempts": 1,
      "history": [
        { "attempt": 1, "action": "resolved", "timestamp": "2026-03-19T10:05:00Z" }
      ]
    }
  ]
}
```

### status transitions

```
OPEN → IN_PROGRESS → DONE
                   → DEFERRED (after 3 failed attempts)
                   → OPEN (requeued after revert)
```

Only the script moves status. The agent does not edit `.codeperfect/issues.json` directly.

## revert discipline

When `scripts/verify.sh` fails after a fix attempt:

1. The script reverts immediately via `git checkout -- .` on tracked files. Untracked files are preserved (never runs `git clean`) to avoid destroying user work.
2. The script records: what was tried, what broke, the verify output.
3. The agent reads the failure record and chooses a **fundamentally different approach** — not a tweak.
4. If the same issue has failed twice, the agent MUST re-read the entire module before attempt 3.
5. After 3 failures, the script marks the issue `DEFERRED` with all three failure reasons.

## safety guardrails

All enforced by the script, not by agent discipline:

- **Max 3 attempts per issue.** The script blocks further attempts after 3 reverts. Non-negotiable.
- **Max iterations.** Hard cap: `max(10, issue_count * 3)`. The script exits with an error if exceeded.
- **No cascading rewrites.** The agent must not modify files outside the scope of the current issue. If `scripts/verify.sh` fails, the script reverts all changes and the agent should check whether the failure is in a file it modified. If verification failures appear in untouched files, the agent should call `fail` with reason "cascading scope" and move on.
- **Checkpoint every 5 resolved issues.** The script runs the full test suite automatically, not just changed-file tests. If new failures appear, the last 5 commits are flagged for review.
- **Atomic commits.** The script commits after each successful resolution with message format: `fix(codeperfect): ISS-N — <description>`. The agent does not commit manually.

## usage

```bash
# Initialize the ledger for a target directory
scripts/resolution-loop.sh init src/

# Scan for issues (populates the ledger)
scripts/resolution-loop.sh scan src/

# Mark an issue as in-progress (agent is working on it)
scripts/resolution-loop.sh start ISS-1

# After a successful fix + verify pass
scripts/resolution-loop.sh resolve ISS-1

# After a failed fix (verify returned non-zero)
scripts/resolution-loop.sh fail ISS-1 "type error: Property 'name' does not exist on type 'User'"

# Add a newly discovered issue
scripts/resolution-loop.sh add "src/api/orders.ts" "78" "medium" "Unhandled promise rejection in checkout flow"

# Check loop status (exit code 0 = done, 1 = continue)
scripts/resolution-loop.sh status

# Print the final report
scripts/resolution-loop.sh report
```

## agent integration

The agent's job in the loop is simple:

1. Read `.codeperfect/issues.json` — pick the highest-severity `OPEN` issue.
2. Call `scripts/resolution-loop.sh start ISS-N`.
3. Read the relevant code files. Apply one fix.
4. Call `scripts/verify.sh`. Read the output.
5. If verify passed: call `scripts/resolution-loop.sh resolve ISS-N`.
6. If verify failed: call `scripts/resolution-loop.sh fail ISS-N "<reason>"`.
7. Call `scripts/resolution-loop.sh status`. If exit code 1, go to step 1.
8. When exit code 0: call `scripts/resolution-loop.sh report`. Done.

The agent never decides whether to continue. The script decides.
