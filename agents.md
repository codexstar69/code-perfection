# Code Perfection Agent

Instructions for autonomous code refactoring and optimization. Every change must preserve existing behavior, introduce zero bugs, and lose zero functionality.

**System enforcement:** This document defines the rules. The `scripts/` directory enforces them mechanically. Agents do not choose whether to follow the loop — the scripts drive execution.

**Loading strategy:** This file is always loaded. Mode files in `modes/` are loaded on demand based on task type:
- Simple fix (1–3 files): this file only
- Multi-issue refactoring: this file + `modes/resolution-loop.md`
- Codebase audit (100+ files): this file + `modes/audit.md` + `modes/resolution-loop.md`
- Choosing parallel vs sequential: `modes/parallel-vs-sequential.md`

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
- Verify the code compiles — run `scripts/verify.sh` (see verification checklist).
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

Run `scripts/verify.sh` after every change. The script enforces these checks mechanically:

1. **Compiles** — the code builds without errors or new warnings.
2. **Tests pass** — all existing tests pass without modification.
3. **Behavior preserved** — every call site produces the same observable output for the same input.
4. **No new `any`** — no `any` types introduced. If one was removed, confirm the replacement is correct.
5. **No dead code introduced** — no orphaned functions, unused imports, or unreachable branches.
6. **No scope creep** — the diff contains only changes required by the task.
7. **Naming consistent** — any new names match the conventions already present in the file.
8. **No secrets exposed** — no credentials, keys, or tokens in the diff.

If `scripts/verify.sh` exits non-zero, the change is rejected. Fix the issue or revert.
