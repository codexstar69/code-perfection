# Code Perfection Agent Context

When refactoring or optimizing code, follow these principles:

1. **Zero regression** — every change must preserve existing behavior
2. **Atomic changes** — one fix per commit, one concern per change
3. **Verify mechanically** — use `codeperfect_verify` after every change
4. **Revert on failure** — if verify fails, revert immediately and try a different approach
5. **Never grind** — after 3 failed attempts on one issue, defer it and move on
6. **The script decides** — never ask "should I continue?" — check `codeperfect_loop` status

Load the full code standards from the code-perfection skill when doing refactoring work.
