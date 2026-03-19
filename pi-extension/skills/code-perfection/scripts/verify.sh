#!/usr/bin/env bash
# Verification checklist — mechanical enforcement.
# Runs after every code change. Exit 0 = pass, non-zero = fail.
# Usage: scripts/verify.sh [--changed-files file1.ts file2.ts ...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

START_TIME=$SECONDS

# git is used for detecting changed files but is not strictly required —
# the script can still run with --changed-files.  We note its absence so
# later steps can skip git-dependent logic gracefully.
HAS_GIT=false
command -v git &>/dev/null && HAS_GIT=true

PASS=0
FAIL=0
WARN=0
FAILURES=""

# Helper: safely get array length (works under set -u on all bash versions)
arrlen() {
  echo "${#@}"
}

check() {
  local name="$1"
  local result="$2"
  local detail="${3:-}"
  if [ "$result" -eq 0 ]; then
    printf "${GREEN}PASS${NC}  %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "${RED}FAIL${NC}  %s\n" "$name"
    [ -n "$detail" ] && printf "       %s\n" "$detail"
    FAIL=$((FAIL + 1))
    FAILURES="${FAILURES}\n  - ${name}: ${detail}"
  fi
}

warn_check() {
  local name="$1"
  local detail="${2:-}"
  printf "${YELLOW}WARN${NC}  %s\n" "$name"
  [ -n "$detail" ] && printf "       %s\n" "$detail"
  WARN=$((WARN + 1))
}

# Parse changed files from args or git
CHANGED_FILES=()
if [ "$#" -gt 0 ] && [ "$1" = "--changed-files" ]; then
  shift
  CHANGED_FILES=("$@")
elif $HAS_GIT && git rev-parse --git-dir &>/dev/null; then
  while IFS= read -r line; do
    [ -n "$line" ] && CHANGED_FILES+=("$line")
  done < <(git diff --name-only HEAD 2>/dev/null || true)
  CHANGED_COUNT=$(arrlen "${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}")
  if [ "$CHANGED_COUNT" -eq 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && CHANGED_FILES+=("$line")
    done < <(git diff --cached --name-only 2>/dev/null || true)
  fi
fi

CHANGED_COUNT=$(arrlen "${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}")

printf "\n=== Code Perfection Verification ===\n\n"

# 1. COMPILES — detect build system and run it
BUILD_RESULT=0
if [ -f "package.json" ]; then
  if command -v bun &>/dev/null; then
    BUILD_CMD="bun run typecheck"
  elif command -v npx &>/dev/null; then
    BUILD_CMD="npx tsc --noEmit"
  else
    BUILD_CMD=""
  fi

  # Verify the typecheck script actually exists in package.json before running
  if [ -n "$BUILD_CMD" ]; then
    if [[ "$BUILD_CMD" == "bun run typecheck" ]]; then
      HAS_TYPECHECK=$(node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.typecheck ? 0 : 1)" 2>/dev/null && echo "yes" || echo "no")
      if [ "$HAS_TYPECHECK" = "no" ]; then
        # Fall back to direct tsc if typecheck script missing
        if command -v npx &>/dev/null; then
          BUILD_CMD="npx tsc --noEmit"
        elif [ -f "node_modules/.bin/tsc" ]; then
          BUILD_CMD="node_modules/.bin/tsc --noEmit"
        else
          BUILD_CMD=""
        fi
      fi
    fi
  fi

  if [ -n "$BUILD_CMD" ]; then
    BUILD_OUTPUT=$($BUILD_CMD 2>&1) || BUILD_RESULT=$?
    check "Compiles (typecheck)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
  else
    warn_check "Compiles" "No TypeScript compiler found — skipping typecheck"
  fi
elif [ -f "Cargo.toml" ]; then
  BUILD_OUTPUT=$(cargo check 2>&1) || BUILD_RESULT=$?
  check "Compiles (cargo check)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
elif [ -f "go.mod" ]; then
  BUILD_OUTPUT=$(go build ./... 2>&1) || BUILD_RESULT=$?
  check "Compiles (go build)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
  if command -v mypy &>/dev/null; then
    BUILD_OUTPUT=$(mypy . 2>&1) || BUILD_RESULT=$?
    check "Compiles (mypy)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
  else
    warn_check "Compiles" "No type checker found for Python — skipping"
  fi
elif [ -f "mix.exs" ]; then
  if command -v mix &>/dev/null; then
    BUILD_OUTPUT=$(mix compile --warnings-as-errors 2>&1) || BUILD_RESULT=$?
    check "Compiles (mix compile)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
  else
    warn_check "Compiles" "mix not found — skipping"
  fi
elif [ -f "CMakeLists.txt" ]; then
  if command -v cmake &>/dev/null; then
    BUILD_OUTPUT=$(cmake --build . 2>&1) || BUILD_RESULT=$?
    check "Compiles (cmake)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
  else
    warn_check "Compiles" "cmake not found — skipping"
  fi
elif [ -f "Makefile" ] || [ -f "makefile" ]; then
  BUILD_OUTPUT=$(make -n 2>&1) || BUILD_RESULT=$?
  if [ $BUILD_RESULT -eq 0 ]; then
    BUILD_OUTPUT=$(make 2>&1) || BUILD_RESULT=$?
  fi
  check "Compiles (make)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
else
  warn_check "Compiles" "No recognized build system — skipping typecheck"
fi

# 2. TESTS PASS — detect test runner and run it
TEST_RESULT=0
if [ -f "package.json" ]; then
  # Check if test script exists
  HAS_TEST=$(node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.test ? 0 : 1)" 2>/dev/null && echo "yes" || echo "no")
  if [ "$HAS_TEST" = "yes" ]; then
    if command -v bun &>/dev/null; then
      TEST_OUTPUT=$(bun run test 2>&1) || TEST_RESULT=$?
    else
      TEST_OUTPUT=$(npm test 2>&1) || TEST_RESULT=$?
    fi
    check "Tests pass" "$TEST_RESULT" "$( [ $TEST_RESULT -ne 0 ] && echo "$TEST_OUTPUT" | tail -10 )"
  else
    warn_check "Tests pass" "No test script in package.json — skipping"
  fi
elif [ -f "Cargo.toml" ]; then
  TEST_OUTPUT=$(cargo test 2>&1) || TEST_RESULT=$?
  check "Tests pass" "$TEST_RESULT" "$( [ $TEST_RESULT -ne 0 ] && echo "$TEST_OUTPUT" | tail -10 )"
elif [ -f "go.mod" ]; then
  TEST_OUTPUT=$(go test ./... 2>&1) || TEST_RESULT=$?
  check "Tests pass" "$TEST_RESULT" "$( [ $TEST_RESULT -ne 0 ] && echo "$TEST_OUTPUT" | tail -10 )"
elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
  if command -v pytest &>/dev/null; then
    TEST_OUTPUT=$(pytest 2>&1) || TEST_RESULT=$?
    check "Tests pass" "$TEST_RESULT" "$( [ $TEST_RESULT -ne 0 ] && echo "$TEST_OUTPUT" | tail -10 )"
  else
    warn_check "Tests pass" "No test runner found — skipping"
  fi
elif [ -f "mix.exs" ]; then
  if command -v mix &>/dev/null; then
    TEST_OUTPUT=$(mix test 2>&1) || TEST_RESULT=$?
    check "Tests pass" "$TEST_RESULT" "$( [ $TEST_RESULT -ne 0 ] && echo "$TEST_OUTPUT" | tail -10 )"
  else
    warn_check "Tests pass" "mix not found — skipping"
  fi
elif [ -f "Makefile" ] || [ -f "makefile" ]; then
  # Check if Makefile has a test target
  if make -n test &>/dev/null; then
    TEST_OUTPUT=$(make test 2>&1) || TEST_RESULT=$?
    check "Tests pass" "$TEST_RESULT" "$( [ $TEST_RESULT -ne 0 ] && echo "$TEST_OUTPUT" | tail -10 )"
  else
    warn_check "Tests pass" "No test target in Makefile — skipping"
  fi
else
  warn_check "Tests pass" "No recognized test framework — skipping"
fi

# 3. NO NEW `any` — check changed TypeScript files
ANY_RESULT=0
TS_CHANGED=()
for f in "${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}"; do
  if [[ "$f" == *.ts || "$f" == *.tsx ]] && [ -f "$f" ]; then
    TS_CHANGED+=("$f")
  fi
done

TS_COUNT=$(arrlen "${TS_CHANGED[@]+"${TS_CHANGED[@]}"}")
if [ "$TS_COUNT" -gt 0 ]; then
  ANY_COUNT=0
  ANY_FILES=""
  for f in "${TS_CHANGED[@]}"; do
    # Count explicit 'any' type annotations (not in comments/strings — rough heuristic)
    # Disable pipefail locally so grep returning 1 (no match) doesn't kill the pipeline
    COUNT=$(set +o pipefail; grep -n ': any\b\|: any;\|: any,\|: any)\|<any>' "$f" 2>/dev/null | grep -v '^\s*//' | wc -l | tr -d ' ')
    if [ "$COUNT" -gt 0 ]; then
      ANY_COUNT=$((ANY_COUNT + COUNT))
      ANY_FILES="${ANY_FILES} ${f}(${COUNT})"
    fi
  done
  if [ "$ANY_COUNT" -gt 0 ]; then
    ANY_RESULT=1
    check "No new any" "$ANY_RESULT" "${ANY_COUNT} any types found in:${ANY_FILES}"
  else
    check "No new any" 0
  fi
else
  check "No new any" 0 "(no TypeScript files changed)"
fi

# 4. NO SECRETS EXPOSED — check for common secret patterns in changed files
SECRET_RESULT=0
if [ "$CHANGED_COUNT" -gt 0 ]; then
  SECRET_MATCHES=""
  for f in "${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}"; do
    [ -f "$f" ] || continue
    # Check for common secret patterns
    # Disable pipefail locally so grep returning 1 (no match) doesn't kill the pipeline
    MATCHES=$(set +o pipefail; grep -inE '(password|secret|api_key|apikey|private_key|access_token)\s*[:=]\s*["\x27][^"\x27]{8,}' "$f" 2>/dev/null | grep -v '^\s*//' | head -3 || true)
    if [ -n "$MATCHES" ]; then
      SECRET_RESULT=1
      SECRET_MATCHES="${SECRET_MATCHES}\n  ${f}: $(echo "$MATCHES" | head -1)"
    fi
  done
  check "No secrets exposed" "$SECRET_RESULT" "$( [ $SECRET_RESULT -ne 0 ] && printf "Possible secrets found:%b" "${SECRET_MATCHES}" )"
else
  check "No secrets exposed" 0 "(no files changed)"
fi

# 5. NO DEAD CODE — check for unused imports in changed TS/JS files
DEAD_RESULT=0
JS_CHANGED=()
for f in "${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}"; do
  if [[ "$f" == *.ts || "$f" == *.tsx || "$f" == *.js || "$f" == *.jsx ]] && [ -f "$f" ]; then
    JS_CHANGED+=("$f")
  fi
done

JS_COUNT=$(arrlen "${JS_CHANGED[@]+"${JS_CHANGED[@]}"}")
if [ "$JS_COUNT" -gt 0 ] && command -v npx &>/dev/null && [ -f "package.json" ]; then
  # Try eslint unused imports check if available
  LINT_OUTPUT=$(npx eslint --no-eslintrc --rule '{"no-unused-vars": "error"}' "${JS_CHANGED[@]}" 2>&1) || DEAD_RESULT=$?
  if [ "$DEAD_RESULT" -ne 0 ]; then
    # Only fail if it's actually unused vars, not eslint config errors
    if echo "$LINT_OUTPUT" | grep -q "no-unused-vars"; then
      check "No dead code (unused vars)" "$DEAD_RESULT" "$(echo "$LINT_OUTPUT" | grep 'no-unused-vars' | head -5)"
    else
      DEAD_RESULT=0
      check "No dead code" 0 "(lint check not applicable)"
    fi
  else
    check "No dead code" 0
  fi
else
  check "No dead code" 0 "(skipped — no JS/TS files or no linter)"
fi

# 6. SCOPE CHECK — fail if too many files changed (hard limit: 20)
if [ "$CHANGED_COUNT" -gt 20 ]; then
  check "No scope creep" 1 "${CHANGED_COUNT} files changed — exceeds hard limit of 20"
elif [ "$CHANGED_COUNT" -gt 10 ]; then
  warn_check "Scope creep" "${CHANGED_COUNT} files changed — review for scope creep"
else
  check "No scope creep" 0
fi

# 7. NAMING CONSISTENT — not mechanically enforceable, agent responsibility
# (listed in agents.md verification checklist as item 7)

# 8. BEHAVIOR PRESERVED — not mechanically enforceable, agent responsibility
# (listed in agents.md verification checklist as item 3)

# Summary
ELAPSED=$((SECONDS - START_TIME))
printf "\n=== Results ===\n"
printf "PASS: %d  |  FAIL: %d  |  WARN: %d  |  Time: %ds\n" "$PASS" "$FAIL" "$WARN" "$ELAPSED"
printf "Files checked: %d\n" "$CHANGED_COUNT"

if [ "$FAIL" -gt 0 ]; then
  printf "${RED}VERIFICATION FAILED${NC}\n"
  printf "Failures:%b\n" "${FAILURES}"
  exit 1
else
  printf "${GREEN}VERIFICATION PASSED${NC}\n"
  exit 0
fi
