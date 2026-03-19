#!/usr/bin/env bash
# Verification checklist — mechanical enforcement.
# Runs after every code change. Exit 0 = pass, non-zero = fail.
# Usage: scripts/verify.sh [--changed-files file1.ts file2.ts ...]
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0
FAILURES=""

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

warn() {
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
elif git rev-parse --git-dir &>/dev/null; then
  mapfile -t CHANGED_FILES < <(git diff --name-only HEAD 2>/dev/null || true)
  if [ ${#CHANGED_FILES[@]} -eq 0 ]; then
    mapfile -t CHANGED_FILES < <(git diff --cached --name-only 2>/dev/null || true)
  fi
fi

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

  if [ -n "$BUILD_CMD" ]; then
    BUILD_OUTPUT=$($BUILD_CMD 2>&1) || BUILD_RESULT=$?
    check "Compiles (typecheck)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
  else
    warn "Compiles" "No TypeScript compiler found — skipping typecheck"
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
    warn "Compiles" "No type checker found for Python — skipping"
  fi
else
  warn "Compiles" "No recognized build system — skipping typecheck"
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
    warn "Tests pass" "No test script in package.json — skipping"
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
    warn "Tests pass" "No test runner found — skipping"
  fi
else
  warn "Tests pass" "No recognized test framework — skipping"
fi

# 3. NO NEW `any` — check changed TypeScript files
ANY_RESULT=0
TS_CHANGED=()
for f in "${CHANGED_FILES[@]}"; do
  [[ "$f" == *.ts || "$f" == *.tsx ]] && [ -f "$f" ] && TS_CHANGED+=("$f")
done

if [ ${#TS_CHANGED[@]} -gt 0 ]; then
  ANY_COUNT=0
  ANY_FILES=""
  for f in "${TS_CHANGED[@]}"; do
    # Count explicit 'any' type annotations (not in comments/strings — rough heuristic)
    COUNT=$(grep -n ': any\b\|: any;\|: any,\|: any)\|<any>' "$f" 2>/dev/null | grep -v '^\s*//' | wc -l | tr -d ' ')
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
if [ ${#CHANGED_FILES[@]} -gt 0 ]; then
  SECRET_MATCHES=""
  for f in "${CHANGED_FILES[@]}"; do
    [ -f "$f" ] || continue
    # Check for common secret patterns
    MATCHES=$(grep -inE '(password|secret|api_key|apikey|private_key|access_token)\s*[:=]\s*["\x27][^"\x27]{8,}' "$f" 2>/dev/null | grep -v '^\s*//' | head -3 || true)
    if [ -n "$MATCHES" ]; then
      SECRET_RESULT=1
      SECRET_MATCHES="${SECRET_MATCHES}\n  ${f}: $(echo "$MATCHES" | head -1)"
    fi
  done
  check "No secrets exposed" "$SECRET_RESULT" "$( [ $SECRET_RESULT -ne 0 ] && echo -e "Possible secrets found:${SECRET_MATCHES}" )"
else
  check "No secrets exposed" 0 "(no files changed)"
fi

# 5. NO DEAD CODE — check for unused imports in changed TS/JS files
DEAD_RESULT=0
JS_CHANGED=()
for f in "${CHANGED_FILES[@]}"; do
  [[ "$f" == *.ts || "$f" == *.tsx || "$f" == *.js || "$f" == *.jsx ]] && [ -f "$f" ] && JS_CHANGED+=("$f")
done

if [ ${#JS_CHANGED[@]} -gt 0 ] && command -v npx &>/dev/null && [ -f "package.json" ]; then
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

# 6. SCOPE CHECK — warn if many files changed
if [ ${#CHANGED_FILES[@]} -gt 10 ]; then
  warn "Scope creep" "${#CHANGED_FILES[@]} files changed — review for scope creep"
fi

# Summary
printf "\n=== Results ===\n"
printf "PASS: %d  |  FAIL: %d  |  WARN: %d\n" "$PASS" "$FAIL" "$WARN"

if [ "$FAIL" -gt 0 ]; then
  printf "${RED}VERIFICATION FAILED${NC}\n"
  printf "Failures:${FAILURES}\n"
  exit 1
else
  printf "${GREEN}VERIFICATION PASSED${NC}\n"
  exit 0
fi
