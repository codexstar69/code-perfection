
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

- Read the existing code first.
- Match the project's naming, file structure, and coding patterns.
- Check `package.json`, `tsconfig.json`, and nearby code before assuming anything about the stack.
- Check existing imports before adding new ones.
- Do not add dependencies unless explicitly asked.
- If a new dependency seems necessary, say so instead of adding it.

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

## output expectations

- Make the change directly.
- Keep the implementation simple and skimmable.
- Keep the diff tight.
- Briefly explain any non-obvious change.
