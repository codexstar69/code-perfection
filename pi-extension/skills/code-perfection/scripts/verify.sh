#!/usr/bin/env bash
# Verification checklist — mechanical enforcement.
# Runs after every code change. Exit 0 = pass, non-zero = fail.
# Usage: scripts/verify.sh [--changed-files file1.ts file2.ts ...]
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# git is used for detecting changed files but is not strictly required —
# the script can still run with --changed-files.  We note its absence so
# later steps can skip git-dependent logic gracefully.
HAS_GIT=false
command -v git &>/dev/null && HAS_GIT=true

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
elif $HAS_GIT && git rev-parse --git-dir &>/dev/null; then
  while IFS= read -r line; do
    [ -n "$line" ] && CHANGED_FILES+=("$line")
  done < <(git diff --name-only HEAD 2>/dev/null || true)
  if [ "${#CHANGED_FILES[@]:-0}" -eq 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && CHANGED_FILES+=("$line")
    done < <(git diff --cached --name-only 2>/dev/null || true)
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
elif [ -f "mix.exs" ]; then
  if command -v mix &>/dev/null; then
    BUILD_OUTPUT=$(mix compile --warnings-as-errors 2>&1) || BUILD_RESULT=$?
    check "Compiles (mix compile)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
  else
    warn "Compiles" "mix not found — skipping"
  fi
elif [ -f "CMakeLists.txt" ]; then
  if command -v cmake &>/dev/null; then
    BUILD_OUTPUT=$(cmake --build . 2>&1) || BUILD_RESULT=$?
    check "Compiles (cmake)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
  else
    warn "Compiles" "cmake not found — skipping"
  fi
elif [ -f "Makefile" ] || [ -f "makefile" ]; then
  BUILD_OUTPUT=$(make -n 2>&1) || BUILD_RESULT=$?
  if [ $BUILD_RESULT -eq 0 ]; then
    BUILD_OUTPUT=$(make 2>&1) || BUILD_RESULT=$?
  fi
  check "Compiles (make)" "$BUILD_RESULT" "$( [ $BUILD_RESULT -ne 0 ] && echo "$BUILD_OUTPUT" | head -5 )"
else
  warn "Compiles" "No recognized build system — skipping typecheck"
fi

# 2. TESTS PASS — detect test runner and run it
TEST_RESULT=0
if [ -f "package.json" ]; then
  # Check if test script exists (grep is faster than spawning node)
  HAS_TEST="no"
  grep -q '"test"' package.json 2>/dev/null && HAS_TEST="yes"
  if [ "$HAS_TEST" = "yes" ]; then
    # Set CI=true to disable watch mode in jest/vitest and avoid interactive prompts
    if command -v bun &>/dev/null; then
      TEST_OUTPUT=$(CI=true bun run test 2>&1) || TEST_RESULT=$?
    else
      TEST_OUTPUT=$(CI=true npm test 2>&1) || TEST_RESULT=$?
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
elif [ -f "mix.exs" ]; then
  if command -v mix &>/dev/null; then
    TEST_OUTPUT=$(mix test 2>&1) || TEST_RESULT=$?
    check "Tests pass" "$TEST_RESULT" "$( [ $TEST_RESULT -ne 0 ] && echo "$TEST_OUTPUT" | tail -10 )"
  else
    warn "Tests pass" "mix not found — skipping"
  fi
elif [ -f "Makefile" ] || [ -f "makefile" ]; then
  # Check if Makefile has a test target
  if make -n test &>/dev/null; then
    TEST_OUTPUT=$(make test 2>&1) || TEST_RESULT=$?
    check "Tests pass" "$TEST_RESULT" "$( [ $TEST_RESULT -ne 0 ] && echo "$TEST_OUTPUT" | tail -10 )"
  else
    warn "Tests pass" "No test target in Makefile — skipping"
  fi
else
  warn "Tests pass" "No recognized test framework — skipping"
fi

# 3. NO NEW `any` — check changed TypeScript files
ANY_RESULT=0
TS_CHANGED=()
for f in "${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}"; do
  if [[ "$f" == *.ts || "$f" == *.tsx ]] && [ -f "$f" ]; then
    TS_CHANGED+=("$f")
  fi
done

if [ "${#TS_CHANGED[@]:-0}" -gt 0 ]; then
  ANY_COUNT=0
  ANY_FILES=""
  for f in "${TS_CHANGED[@]}"; do
    # Count explicit 'any' type annotations (not in comments/strings — rough heuristic)
    COUNT=$(grep -nE ':\s*any\s*[;,)>\s]|:\s*any\s*$|<any>' "$f" 2>/dev/null | grep -v '^\s*//' | wc -l | tr -d ' ')
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
if [ "${#CHANGED_FILES[@]:-0}" -gt 0 ]; then
  SECRET_MATCHES=""
  for f in "${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}"; do
    [ -f "$f" ] || continue
    # Check for common secret patterns
    MATCHES=$(grep -inE "(password|secret|api_key|apikey|private_key|access_token)\s*[:=]\s*[\"'][^\"']{8,}" "$f" 2>/dev/null | grep -v '^\s*//' | head -3 || true)
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

if [ "${#JS_CHANGED[@]:-0}" -gt 0 ] && [ -f "package.json" ]; then
  # Fast unused-import detection via grep (avoids slow npx eslint cold start).
  # For each changed file, extract named imports and check if they appear
  # elsewhere in the file beyond the import line.
  DEAD_CHECKED=false
  UNUSED_IMPORTS=""
  UNUSED_COUNT=0

  for f in "${JS_CHANGED[@]}"; do
    # Extract named imports: import { Foo, Bar } from '...'
    while IFS= read -r import_name; do
      [ -z "$import_name" ] && continue
      # Count occurrences of the import name in the file (excluding import lines)
      USES=$(grep -c "\b${import_name}\b" "$f" 2>/dev/null || echo "0")
      # Subtract the import declaration itself (at least 1 occurrence)
      if [ "$USES" -le 1 ]; then
        UNUSED_COUNT=$((UNUSED_COUNT + 1))
        UNUSED_IMPORTS="${UNUSED_IMPORTS}\n  ${f}: unused import '${import_name}'"
      fi
    done < <(grep -oE 'import\s*\{[^}]+\}' "$f" 2>/dev/null | sed 's/import\s*{//;s/}//' | tr ',' '\n' | sed 's/\s*as\s.*//;s/[[:space:]]//g' | grep -v '^$')
  done

  if [ "$UNUSED_COUNT" -gt 0 ]; then
    DEAD_RESULT=1
    check "No dead code (unused imports)" "$DEAD_RESULT" "$(printf '%d potentially unused imports:%b' "$UNUSED_COUNT" "$UNUSED_IMPORTS" | head -8)"
  else
    check "No dead code" 0
  fi
  DEAD_CHECKED=true
else
  check "No dead code" 0 "(skipped — no JS/TS files or no package.json)"
fi

# 6. SCOPE CHECK — fail if too many files changed (hard limit: 20)
if [ "${#CHANGED_FILES[@]:-0}" -gt 20 ]; then
  check "No scope creep" 1 "${#CHANGED_FILES[@]} files changed — exceeds hard limit of 20"
elif [ "${#CHANGED_FILES[@]:-0}" -gt 10 ]; then
  warn "Scope creep" "${#CHANGED_FILES[@]} files changed — review for scope creep"
else
  check "No scope creep" 0
fi

# 7. NAMING CONSISTENT — not mechanically enforceable, agent responsibility
# (listed in agents.md verification checklist as item 7)

# 8. BEHAVIOR PRESERVED — not mechanically enforceable, agent responsibility
# (listed in agents.md verification checklist as item 3)

# Summary
printf "\n=== Results ===\n"
printf "PASS: %d  |  FAIL: %d  |  WARN: %d\n" "$PASS" "$FAIL" "$WARN"

if [ "$FAIL" -gt 0 ]; then
  printf "${RED}VERIFICATION FAILED${NC}\n"
  printf "Failures:%b\n" "${FAILURES}"
  exit 1
else
  printf "${GREEN}VERIFICATION PASSED${NC}\n"
  exit 0
fi
