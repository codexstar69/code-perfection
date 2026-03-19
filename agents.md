# Code Perfection Agent

Instructions for autonomous code refactoring and optimization. Every change must preserve existing behavior, introduce zero bugs, and lose zero functionality.

## core instruction

Do only the work required for the task.
Preserve behavior unless the task explicitly requires behavior changes.
Keep the diff as small as possible.

## code philosophy

Write code a human can skim and still understand.
If a line needs to be re-read, it is too complex.

## rules

### simplicity

- Prefer fewer lines of code, but never at the cost of readability.
- No clever code.
- No `reduce` chains, nested ternaries, curried helpers, or dense one-liners.
- Prefer straightforward control flow.
- Use early returns instead of nested `if/else`.
- Do not split code into many small functions unless it clearly makes the result easier to read.
- If a function is only called once and is small, inline it.
- Do not add comments that just restate what the code already says.
- The code should explain itself.

### types and state

- Minimize the number of possible states.
- Prefer narrower types, fewer arguments, and fewer optional values.
- Make invalid states unrepresentable where practical.
- Use discriminated unions for values that can be in different shapes.

```ts
// bad
type Result<T> = { error?: string; data?: T };

// good
type Result<T> =
  | { type: 'error'; message: string }
  | { type: 'success'; data: T };
```

- Handle discriminated unions exhaustively.
- In the unreachable branch, use `never` and fail loudly.

```ts
default: {
  const _exhaustive: never = value;
  throw new Error(`unknown type: ${String(_exhaustive)}`);
}
```

- Do not make arguments optional if they are actually required.
- Be honest in the type signature.
- If a function needs more than 3 arguments, reconsider the design before adding more.

### assertions over defensiveness

- Do not write defensive code for impossible internal states.
- Trust the types once data is validated.
- Use assertions at data-loading or input boundaries.
- If something must exist, assert it exists.
- Do not silently swallow errors.
- Do not add fallback defaults for values that should be present.

```ts
const user = users.find((u) => u.id === id);
assert(user, `user not found: ${id}`);
```

- Use `try/catch` only for real I/O boundaries like network, filesystem, or parsing boundaries where failure is expected.
- Do not wrap code in `try/catch` "just in case".

### scope discipline

- Do not modify code outside the scope of the task.
- Do not refactor adjacent code unless it is required to complete the task.
- Do not rename variables, functions, types, files, or exports unless the task requires it.
- Do not reorganize files or imports unless required.
- Remove only what is strictly unnecessary.
- Add only what is strictly necessary.
- If existing code is ugly but unrelated and working, leave it alone.
- If a rule here conflicts with established project patterns, follow the project unless the task requires otherwise.

### arguments and overrides

- Keep argument count low.
- Prefer positional arguments for 1–2 required values.
- Prefer a single typed object for 3 required values.
- Do not introduce config bags or override objects unless they are genuinely necessary.
- Do not use `options?: Partial<Config>` unless the API truly needs partial configuration.

### abstractions

- No new abstractions without a second real use case.
- One caller usually means inline it.
- Do not extract helpers unless extraction clearly improves readability.
- Do not create wrapper functions that just pass values through.
- No barrel exports unless the project already uses them.

### interfaces and contracts

- Keep function signatures stable. Changing a public function's signature is a breaking change — all callers must be updated.
- Prefer adding new functions over modifying existing signatures when extending behavior.
- Return consistent types. A function should not return `string | undefined | null` — pick one failure representation.
- Document non-obvious preconditions and postconditions in the type signature, not in comments.

### naming and conventions

- Use descriptive names that reveal intent. Avoid abbreviations except widely understood ones (`id`, `url`, `config`).
- Match existing naming patterns in the codebase — consistency beats personal preference.
- Boolean variables and functions should read as questions: `isValid`, `hasPermission`, `canRetry`.
- Avoid flag arguments that toggle behavior. Prefer separate functions or explicit options.

```ts
// bad — boolean flag hides intent
function getUser(id: string, includeDeleted: boolean) {}

// good — explicit, self-documenting
function getUser(id: string) {}
function getUserIncludingDeleted(id: string) {}
```

### modules and dependencies

- Keep imports minimal. Import only what you use.
- Prefer named imports over namespace imports (`import * as`) unless the namespace is conventional (e.g., `path`, `fs`).
- Do not introduce circular dependencies. If module A imports from B and B needs something from A, extract the shared piece into a third module.
- Group imports logically: external packages first, then internal modules, then relative imports.
- Do not re-export from index files unless the project already follows that pattern.

### dead code and duplication

- Remove dead code immediately. Do not comment it out "for reference" — git history preserves it.
- Remove unused imports, variables, functions, and types.
- Tolerate small amounts of duplication. Two or three similar lines are better than a premature abstraction.
- Only extract shared code when duplication is exact and appears three or more times.

### complexity management

- Reduce cyclomatic and cognitive complexity. Flatten deeply nested logic.
- Prefer guard clauses and early returns over deeply nested conditionals.
- If a function does more than one thing, consider splitting it — but only if both pieces are independently meaningful.
- Avoid long parameter lists, long functions, and long files as signals of excessive complexity.

```ts
// bad — deeply nested
function process(input: Input) {
  if (input.isValid) {
    if (input.hasData) {
      if (input.data.length > 0) {
        return transform(input.data);
      }
    }
  }
  return null;
}

// good — guard clauses
function process(input: Input) {
  if (!input.isValid) return null;
  if (!input.hasData) return null;
  if (input.data.length === 0) return null;
  return transform(input.data);
}
```

### concurrency and async

- Avoid shared mutable state between concurrent operations.
- Prefer `Promise.all` for independent async operations over sequential `await`.
- Always handle promise rejections. Never leave a promise floating without a catch path.
- Watch for race conditions when multiple async operations modify the same resource.

```ts
// bad — sequential when independent
const users = await fetchUsers();
const orders = await fetchOrders();

// good — parallel when independent
const [users, orders] = await Promise.all([fetchUsers(), fetchOrders()]);
```

### error handling

- Let errors propagate naturally. Only catch errors when you can do something meaningful with them.
- Prefer typed errors over generic `Error`. Use custom error classes or result types for expected failure modes.
- Never catch and ignore. If you catch, log, rethrow, or handle — never silently swallow.
- Distinguish between programmer errors (bugs — let them crash) and operational errors (expected failures — handle gracefully).

```ts
// bad — catches everything, hides bugs
try {
  return processOrder(order);
} catch {
  return null;
}

// good — handles specific expected failure
try {
  return processOrder(order);
} catch (error) {
  if (error instanceof InsufficientFundsError) {
    return { status: 'declined', reason: error.message };
  }
  throw error; // unexpected errors propagate
}
```

### validation boundaries

- Validate at the edges: API handlers, CLI parsers, file readers, message consumers.
- Once data crosses the boundary and is validated, trust the types. Do not re-validate internally.
- Use parsing (transform + validate) over validation (check + assert). Parse once, use the parsed type everywhere.

```ts
// bad — validate at every layer
function createUser(data: unknown) {
  if (!data || typeof data !== 'object') throw new Error('invalid');
  // ...more manual checks
}

// good — parse at the boundary, trust the type after
const CreateUserSchema = z.object({ name: z.string(), email: z.string().email() });
type CreateUser = z.infer<typeof CreateUserSchema>;

function handleRequest(raw: unknown) {
  const data = CreateUserSchema.parse(raw); // boundary
  return createUser(data); // typed, no further validation needed
}
function createUser(data: CreateUser) { /* trust the type */ }
```

### security

- Never interpolate user input directly into SQL, shell commands, or HTML.
- Validate and sanitize all external input at system boundaries.
- Do not log sensitive data — passwords, tokens, API keys, or PII.
- Do not hardcode secrets or credentials. Use environment variables or a secrets manager.

### logging and observability

- Log at appropriate levels: errors for failures, warnings for degraded state, info for key events, debug for development.
- Include enough context to diagnose issues — request IDs, user IDs, operation names.
- Do not log excessively in hot paths. Logging has a cost.
- Prefer structured logging (key-value pairs) over string concatenation.

```ts
// bad — unstructured, missing context
console.log('User login failed');

// good — structured with context
logger.warn('login_failed', { userId, reason: 'invalid_credentials', ip: req.ip });
```

### patterns and anti-patterns

- Avoid code smells: long methods, god objects, feature envy, shotgun surgery.
- Prefer composition over inheritance.
- Do not use singletons unless the runtime genuinely requires a single instance.
- Avoid magic numbers and magic strings. Extract named constants when the value is not self-evident.

```ts
// bad — magic number
if (retries > 3) throw new Error('too many retries');

// good — named constant
const MAX_RETRIES = 3;
if (retries > MAX_RETRIES) throw new Error('too many retries');
```

### variables and immutability

- Default to `const`. Only use `let` when reassignment is genuinely needed.
- Never use `var`.
- Prefer immutable data. Clone-and-modify over mutate-in-place, unless performance is measured and critical.
- Do not reassign function parameters. Create a new variable instead.

### performance

- Do not optimize without evidence. Premature optimization creates complexity without measurable benefit.
- Profile before optimizing. Use benchmarks, flame graphs, or production metrics to identify real bottlenecks.
- Avoid allocations in hot loops — reuse buffers, pre-allocate arrays, avoid string concatenation.
- Prefer algorithmic improvements (O(n²) → O(n log n)) over micro-optimizations.
- Cache expensive computations only when the cost is measured and the cache invalidation strategy is clear.

### loops and iteration

- Prefer `for...of` for iterating arrays when you need the value.
- Prefer `.map`, `.filter`, `.some`, `.every` for declarative transforms — but not when they hurt readability.
- Avoid `for...in` for arrays. It iterates over keys, not values.
- Break out of loops early when the result is already determined.

### react-specific rules

- Do not add `useCallback`, `useMemo`, or `React.memo` unless there is a measured performance problem.
- Do not add new state just to make the code feel more "structured".
- Do not add loading states, error boundaries, empty states, or edge-case UI unless the task asks for them.
- Ship the happy path first.

## behavior

### before writing code

- Read the existing code first. Understand what it does and why before changing it.
- Identify all call sites of any function or type you plan to modify.
- Match the project's naming, file structure, and coding patterns.
- Check `package.json`, `tsconfig.json`, and nearby code before assuming anything about the stack.
- Check existing imports before adding new ones.
- Do not add dependencies unless explicitly asked.
- If a new dependency seems necessary, say so instead of adding it.
- Run existing tests to establish a passing baseline before making changes.

### while writing code

- Preserve behavior unless told otherwise.
- Do not change build config, tsconfig, eslint, prettier, CI, or tooling files.
- Do not add polyfills, compatibility shims, or framework-level helpers.
- Do not create new files if the obvious place is an existing file.
- Do not move code between files unless the task requires it.
- Prefer the smallest change that fully solves the problem.
- When choosing between a slightly cleaner abstraction and a more obvious inline solution, choose the obvious inline solution.

### after writing code

- If you touched files outside the task scope, undo those changes.
- Remove any refactors that are not strictly required.
- Do not leave TODO comments.
- Do not add tests unless asked.
- Do not add broad typing cleanup unless asked.
- Verify the code compiles.
- If an import, API, or type is uncertain, check it before using it.

## refactoring methodology

### zero-regression guarantee

- Every refactoring must be behavior-preserving. If you cannot prove equivalence, do not make the change.
- Run existing tests before and after. If no tests exist, verify by reading every call site.
- Never refactor and change behavior in the same commit. Separate structural changes from behavioral changes.
- When in doubt, the safer change wins. A missed optimization is better than a broken feature.

### refactoring priorities

1. **Fix correctness issues** — bugs, race conditions, resource leaks.
2. **Eliminate dead code** — unused functions, unreachable branches, orphaned imports.
3. **Reduce complexity** — flatten nesting, extract guard clauses, simplify conditionals.
4. **Improve type safety** — narrow types, remove `any`, add discriminated unions.
5. **Consolidate duplication** — only when three or more identical patterns exist.
6. **Improve naming** — only when the current name is actively misleading.
7. **Optimize performance** — only with evidence of a bottleneck. Never speculate.

### what not to refactor

- Code that works and is not part of the current task.
- Code whose meaning you do not fully understand.
- Code with no test coverage unless you are adding tests first.
- Code that is "ugly" but correct and unlikely to change.

## output expectations

- Make the change directly.
- Keep the implementation simple and skimmable.
- Keep the diff tight.
- Briefly explain any non-obvious change.
- If a refactoring changes more than 50 lines, break it into smaller, independently correct steps.

## verification checklist

Run through this checklist after every change. Do not skip steps.

1. **Compiles** — the code builds without errors or new warnings.
2. **Tests pass** — all existing tests pass without modification.
3. **Behavior preserved** — every call site produces the same observable output for the same input.
4. **No new `any`** — no `any` types introduced. If one was removed, confirm the replacement is correct.
5. **No dead code introduced** — no orphaned functions, unused imports, or unreachable branches.
6. **No scope creep** — the diff contains only changes required by the task.
7. **Naming consistent** — any new names match the conventions already present in the file.
8. **No secrets exposed** — no credentials, keys, or tokens in the diff.

---

## resolution loop

Every refactoring task runs inside a resolution loop. The loop does not exit until all issues are resolved or explicitly deferred. No partial work. No "good enough." Fix it or explain why it cannot be fixed.

### loop protocol

```
ITERATION = 0

1. SCAN    — identify all issues in scope (see "large codebase audit" below)
2. PLAN    — rank issues by severity, group by file/module, estimate blast radius
3. FIX     — apply ONE atomic change (single concern, single commit)
4. VERIFY  — run verification checklist (above) + any project-specific checks
5. DECIDE  —
   IF verify passes AND issue is resolved:
       mark issue DONE, commit, go to step 6
   IF verify fails (tests break, types error, behavior changes):
       revert the change immediately
       record what went wrong and why
       try a different approach (max 3 attempts per issue)
       if 3 attempts fail: mark issue DEFERRED with reason, go to step 6
   IF verify passes BUT introduced a new issue:
       add the new issue to the queue
       commit the fix, go to step 6
6. PROGRESS CHECK —
   remaining = issues where status != DONE and status != DEFERRED
   IF remaining == 0: EXIT loop — all issues resolved
   IF remaining > 0: ITERATION++, go to step 3
   NEVER ask "should I continue?" — if issues remain, continue.
```

### issue tracking during the loop

Maintain a live issue ledger. Every issue has exactly one status at any time:

| Status | Meaning |
|--------|---------|
| `OPEN` | Identified, not yet attempted |
| `IN_PROGRESS` | Currently being worked on |
| `DONE` | Fixed and verified |
| `DEFERRED` | Cannot fix safely — requires human decision or broader context |

Rules:
- New issues discovered during fixing get status `OPEN` and enter the queue.
- An issue moves to `DEFERRED` only after 3 failed fix attempts with documented reasons.
- The loop exits when zero issues have status `OPEN` or `IN_PROGRESS`.
- After exit, report the final ledger: how many DONE, how many DEFERRED and why.

### revert discipline

When a fix fails verification:
1. Revert immediately. Do not try to patch the patch.
2. Record: what was tried, what broke, why.
3. Use the failure information to choose a fundamentally different approach — not a tweak of the same idea.
4. If the same file has been reverted twice, step back and re-read the entire module before the third attempt.

### loop safety guardrails

- **Max 3 attempts per issue.** After 3 reversions on the same issue, mark it `DEFERRED`. Do not grind.
- **Max iterations.** For bounded runs, set a hard cap. Default: `max(10, issue_count * 3)`.
- **No cascading rewrites.** If fixing issue A requires rewriting module B which breaks module C — stop. Mark A as `DEFERRED` with reason "cascading scope." Fix A requires a separate, dedicated task.
- **Checkpoint after every 5 resolved issues.** Run the full test suite, not just the files you touched. Catch drift early.

---

## large codebase audit strategy

Auditing a large codebase (100+ files) requires a systematic approach to avoid losing context, missing issues, or wasting effort re-reading code. The strategy is domain-first, tiered, and state-driven.

### why naive approaches fail at scale

- **Flat file-by-file scanning** loses domain context. Reading `auth/login.ts` then `billing/invoice.ts` in the same pass means you understand neither domain deeply.
- **Reading everything at once** overflows working memory. By file 40 you have forgotten file 5.
- **Random sampling** misses the most dangerous bugs — those at domain boundaries where assumptions change between services.

### tier 0: rapid structural recon (no code reading)

Before reading any code, map the codebase structure:

1. **Discover domains** — list top-level directories (2 levels deep max). Each directory cluster is a "domain."
2. **Count files per domain** — know the size of each area.
3. **Classify domains by risk tier:**

| Tier | Domains | Why |
|------|---------|-----|
| CRITICAL | auth, payments, security, API gateways, middleware | Direct attack surface, data integrity |
| HIGH | core business logic, database models, state management | Behavioral correctness, data flow |
| MEDIUM | utilities, helpers, formatting, UI components | Lower blast radius |
| LOW | config, scripts, migrations, static assets | Rarely contain behavioral bugs |

4. **Write the domain map.** This is your audit roadmap. Persist it so subsequent iterations do not re-scan.

### tier 1: domain-scoped deep audits

Process ONE domain at a time. Run the full audit pipeline within each domain before moving to the next:

```
For each domain (CRITICAL first → HIGH → MEDIUM → LOW):
  1. Read ALL files in this domain — build a complete mental model
  2. Identify issues: complexity, dead code, type gaps, bugs, duplication
  3. Record every issue in the ledger with file, line, severity, description
  4. Enter the resolution loop for this domain's issues
  5. Mark domain as DONE in the audit state

  Persist results per domain:
    audit/<domain-name>/issues.md
    audit/<domain-name>/status.json   (DONE / IN_PROGRESS / PENDING)
```

**Why one domain at a time:** The agent maintains full context for the entire domain — middleware, models, routes, utils — in one coherent pass. Issues that span multiple files within the domain are visible. The Skeptic/Referee pattern (challenge your own findings) works because you have full context to both find and verify.

**If a domain exceeds working memory capacity:**
- Chunk within the domain boundary. Split by subdirectory or logical grouping.
- Never chunk across domains — that destroys coherence.
- Process chunks sequentially within the domain. After all chunks, do a cross-chunk consistency check.

### tier 2: cross-domain boundary audit

After all individual domains are audited, run a focused pass on service boundaries — where the most dangerous bugs hide:

1. **Identify boundary files** — files that import from other domains.
2. **Build boundary pairs** — group by the two domains they connect:
   ```
   auth ↔ api-gateway:  [gateway/auth-middleware.ts, auth/token-service.ts]
   billing ↔ orders:    [orders/checkout.ts, billing/charge.ts]
   ```
3. **For each boundary pair**, read files from BOTH domains simultaneously and check for:
   - **Trust boundary violations** — does domain A trust unvalidated data from domain B?
   - **Contract mismatches** — does the caller assume a return type the callee doesn't guarantee?
   - **Race conditions** across domain boundaries.
   - **Auth/permission gaps** — is a function reachable from both protected and unprotected routes?
   - **Partial failure states** — multi-step cross-domain operations where step 2 fails but step 1's side effects aren't rolled back.
4. Record boundary issues in the ledger and resolve them through the same loop.

### tier 3: merge, deduplicate, report

After all domains and boundaries are audited:
1. Merge all domain issue ledgers.
2. Deduplicate by file + line + description.
3. Produce the final report: issues resolved, issues deferred, coverage achieved.

### audit state management

Persist audit progress so interruptions do not lose work:

```json
{
  "domains": {
    "auth": { "status": "done", "issues_found": 12, "issues_resolved": 11, "issues_deferred": 1 },
    "billing": { "status": "in_progress", "issues_found": 5, "issues_resolved": 2 },
    "orders": { "status": "pending" }
  },
  "boundaries": {
    "auth-billing": { "status": "pending" }
  },
  "total_resolved": 13,
  "total_deferred": 1,
  "last_updated": "2026-03-19T10:00:00Z"
}
```

**Resume rule:** On restart, read the state file. Skip domains marked `done`. Resume from the first `in_progress` or `pending` domain. Never re-audit `done` domains unless the code has changed since the audit.

---

## parallel vs sequential: decision framework

Not every audit task benefits from parallelism. Use the wrong mode and you waste effort, create conflicts, or miss cross-file bugs. Use this decision framework.

### when to audit sequentially

Sequential is the default. Use it when:

- **Files are interdependent.** If file A's correctness depends on understanding file B (shared types, call chains, middleware stacks), they must be audited in the same pass.
- **The domain is small.** Under 40 files, the overhead of splitting and merging exceeds the time saved.
- **Cross-file bugs are likely.** Contract mismatches, error propagation gaps, and state management bugs require reading multiple files with full context. Parallel agents miss these.
- **You are fixing, not just scanning.** Fixes modify files. Two parallel agents modifying files in the same directory will conflict. Fixing is always sequential — one writer at a time.
- **The boundary audit phase.** Boundary pairs must read files from both domains simultaneously. This is inherently sequential per pair.

### when to audit in parallel

Parallel scanning is safe when the work units are independent and read-only:

- **Multiple independent domains.** Domain `auth` and domain `billing` have no shared files. Two agents can scan them simultaneously, each maintaining full context of their own domain.
- **Read-only triage passes.** A quick parallel sweep with two "lenses" (security lens + logic lens) over the same files can surface hints faster. But the results are not final — they feed into a sequential deep scan.
- **Skeptic/challenger on independent finding sets.** If findings fall cleanly into separate directories, two Skeptics can challenge their own subsets in parallel.
- **Independent verification tasks.** Typecheck, lint, and test suite runs are naturally parallel.

### the hybrid pattern (recommended for medium-to-large codebases)

```
Phase 1: Parallel read-only triage
  → Two agents scan the same files with different lenses (security, logic)
  → Produces a combined shortlist of suspicious areas

Phase 2: Sequential deep audit
  → One agent reads every file in risk-map order
  → Uses triage hints to prioritize but scans ALL files
  → Produces the authoritative issue list

Phase 3: Parallel challenge (if findings split cleanly by directory)
  → Skeptic A challenges findings in service/auth
  → Skeptic B challenges findings in service/billing
  → Merge results

Phase 4: Sequential resolution loop
  → One agent fixes issues one at a time
  → Commits after each fix, reverts on failure
  → Never two writers in the same codebase
```

### parallel safety rules

- **Read-only agents may run in parallel.** They read files and produce reports. They never modify code.
- **Writing agents must be sequential.** One writer at a time. Use a lock if the system supports it.
- **Never merge parallel findings blindly.** After parallel scanning, deduplicate by file + line. If two agents report different issues on the same line, a sequential tiebreaker pass reads the code and decides.
- **Parallel agents must not share state.** Each agent writes to its own output file. Merging happens after all agents complete.
- **If a parallel agent fails, the work is not lost.** The successful agent's results stand. Re-run only the failed agent's scope.

### context preservation tactics

Large audits risk losing context as the agent's working memory fills. Mitigate this:

- **Write findings to disk between phases.** Do not carry the full issue list in memory. Read it from disk at the start of each phase.
- **One domain at a time.** Finish domain A completely before starting domain B. Never interleave.
- **Checkpoint after each domain.** Write the domain's issue ledger, mark it done, then deliberately "reset" — re-read the next domain's files fresh.
- **If earlier files are becoming hazy, stop expanding.** Finish the current file thoroughly rather than skimming five more files poorly. Partial coverage with high confidence beats full coverage with low confidence. The loop will cover the rest next iteration.
- **Persist the risk map.** The structural recon (tier 0) is done once and persisted. Subsequent iterations read it from disk instead of re-scanning.
- **Use the audit state file as the single source of truth.** Not memory. Not git log. The state file says what is done, what remains, and where to resume.

### decision summary

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
                 │         │
                 ▼         ▼
            PARALLEL    SEQUENTIAL
          (safe — no   (must maintain
          shared state) cross-file context)
```
