#!/usr/bin/env bash
# Resolution loop — mechanical enforcement of the fix-verify-decide cycle.
# Manages the issue ledger, enforces revert-on-failure, blocks exit until clean.
# Usage: scripts/resolution-loop.sh <command> [args...]
set -euo pipefail

# Dependency check
if ! command -v python3 &>/dev/null; then
  printf "ERROR: python3 is required but not found in PATH.\n" >&2
  exit 1
fi
if ! command -v git &>/dev/null; then
  printf "ERROR: git is required but not found in PATH.\n" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR=".codeperfect"
ISSUES_FILE="$STATE_DIR/issues.json"
LOCK_FILE="$STATE_DIR/fix.lock"
ITERATION_FILE="$STATE_DIR/iteration-count"
MAX_ATTEMPTS=3

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

ensure_issues_file() {
  if [ ! -f "$ISSUES_FILE" ]; then
    printf '{"version":1,"created":"%s","issues":[]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ISSUES_FILE"
  fi
}

cleanup_lock() {
  # Only remove lockfile if we are the owner
  if [ -f "$LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ "$lock_pid" = "$$" ]; then
      rm -f "$LOCK_FILE"
    fi
  fi
}

acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf "${RED}ERROR${NC}: Lock held by PID %s. Another resolution loop is running.\n" "$pid"
      exit 1
    fi
    printf "${YELLOW}WARN${NC}: Stale lock found (PID %s not running). Removing.\n" "$pid"
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  trap cleanup_lock EXIT INT TERM
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# Generate next issue ID
next_id() {
  local max_id
  max_id=$(CP_ISSUES_FILE="$ISSUES_FILE" python3 -c "
import json, os, sys
with open(os.environ['CP_ISSUES_FILE']) as f:
    data = json.load(f)
ids = [int(i['id'].replace('ISS-','')) for i in data['issues'] if i['id'].startswith('ISS-')]
print(max(ids) + 1 if ids else 1)
" 2>/dev/null || echo "1")
  echo "ISS-$max_id"
}

# Commands
cmd_init() {
  local target="${1:-.}"
  ensure_state_dir
  printf '{"version":1,"created":"%s","target":"%s","issues":[]}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$target" > "$ISSUES_FILE"
  # Reset iteration counter
  echo "0" > "$ITERATION_FILE"
  printf "${GREEN}Initialized${NC} issue ledger at %s for target: %s\n" "$ISSUES_FILE" "$target"
}

cmd_add() {
  if [ $# -lt 4 ]; then
    printf "${RED}ERROR${NC}: add requires 4 arguments: <file> <line> <severity> <description>\n" >&2
    exit 1
  fi
  local file="$1"
  local line="$2"
  local severity="$3"
  local description="$4"
  ensure_issues_file

  local id
  id=$(next_id)

  CP_ISSUES_FILE="$ISSUES_FILE" CP_ID="$id" CP_FILE="$file" \
  CP_LINE="$line" CP_SEVERITY="$severity" CP_DESC="$description" \
  python3 -c "
import json, os, sys
issues_file = os.environ['CP_ISSUES_FILE']
with open(issues_file) as f:
    data = json.load(f)
data['issues'].append({
    'id': os.environ['CP_ID'],
    'file': os.environ['CP_FILE'],
    'line': int(os.environ['CP_LINE']),
    'severity': os.environ['CP_SEVERITY'],
    'description': os.environ['CP_DESC'],
    'status': 'open',
    'attempts': 0,
    'history': []
})
with open(issues_file, 'w') as f:
    json.dump(data, f, indent=2)
"
  printf "${GREEN}Added${NC} %s [%s] %s:%s — %s\n" "$id" "$severity" "$file" "$line" "$description"
}

cmd_scan() {
  local target="${1:-.}"
  ensure_state_dir
  ensure_issues_file
  printf "${CYAN}Scanning${NC} %s for issues...\n" "$target"
  printf "${YELLOW}NOTE${NC}: The agent must populate the ledger by calling 'add' for each issue found.\n"
  printf "       Run: scripts/resolution-loop.sh add <file> <line> <severity> <description>\n"
}

cmd_start() {
  if [ $# -lt 1 ]; then
    printf "${RED}ERROR${NC}: start requires 1 argument: <ISS-N>\n" >&2
    exit 1
  fi
  local id="$1"
  acquire_lock

  local start_result=0
  CP_ISSUES_FILE="$ISSUES_FILE" CP_ID="$id" CP_MAX="$MAX_ATTEMPTS" \
  python3 -c "
import json, os, sys
issues_file = os.environ['CP_ISSUES_FILE']
issue_id = os.environ['CP_ID']
max_attempts = int(os.environ['CP_MAX'])
with open(issues_file) as f:
    data = json.load(f)
found = False
for issue in data['issues']:
    if issue['id'] == issue_id:
        if issue['status'] == 'deferred':
            print(f'ERROR: {issue_id} is DEFERRED — cannot restart')
            sys.exit(1)
        if issue['attempts'] >= max_attempts:
            print(f'ERROR: {issue_id} has exhausted all {max_attempts} attempts — auto-deferring')
            issue['status'] = 'deferred'
            issue['history'].append({'attempt': issue['attempts'], 'action': 'auto-deferred', 'reason': 'max attempts reached'})
            with open(issues_file, 'w') as f:
                json.dump(data, f, indent=2)
            sys.exit(1)
        issue['status'] = 'in_progress'
        found = True
        break
if not found:
    print(f'ERROR: {issue_id} not found')
    sys.exit(1)
with open(issues_file, 'w') as f:
    json.dump(data, f, indent=2)
" || start_result=$?

  if [ "$start_result" -ne 0 ]; then
    release_lock
    exit 1
  fi
  printf "${CYAN}Started${NC} %s\n" "$id"
}

cmd_resolve() {
  if [ $# -lt 1 ]; then
    printf "${RED}ERROR${NC}: resolve requires 1 argument: <ISS-N>\n" >&2
    exit 1
  fi
  local id="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  CP_ISSUES_FILE="$ISSUES_FILE" CP_ID="$id" CP_TIMESTAMP="$timestamp" \
  python3 -c "
import json, os, sys
issues_file = os.environ['CP_ISSUES_FILE']
issue_id = os.environ['CP_ID']
timestamp = os.environ['CP_TIMESTAMP']
with open(issues_file) as f:
    data = json.load(f)
found = False
for issue in data['issues']:
    if issue['id'] == issue_id:
        found = True
        if issue['status'] != 'in_progress':
            print(f'ERROR: {issue_id} has status \"{issue[\"status\"]}\" — must be in_progress to resolve')
            sys.exit(1)
        issue['status'] = 'done'
        issue['attempts'] += 1
        issue['history'].append({
            'attempt': issue['attempts'],
            'action': 'resolved',
            'timestamp': timestamp
        })
        break
if not found:
    print(f'ERROR: {issue_id} not found')
    sys.exit(1)
with open(issues_file, 'w') as f:
    json.dump(data, f, indent=2)
" || { release_lock; exit 1; }

  # Auto-commit the fix
  if git rev-parse --git-dir &>/dev/null; then
    local desc
    desc=$(CP_ISSUES_FILE="$ISSUES_FILE" CP_ID="$id" python3 -c "
import json, os
with open(os.environ['CP_ISSUES_FILE']) as f:
    data = json.load(f)
for issue in data['issues']:
    if issue['id'] == os.environ['CP_ID']:
        print(issue['description'])
        break
")
    # Stage only tracked files that changed (not untracked files which may be
    # unrelated user work). Exclude the .codeperfect state directory.
    git add --update -- ':!.codeperfect'
    # Only commit if there are staged changes
    if ! git diff --cached --quiet 2>/dev/null; then
      local commit_msg
      commit_msg=$(printf 'fix(codeperfect): %s — %s' "$id" "$desc")
      if ! git commit -m "$commit_msg"; then
        printf "${YELLOW}WARN${NC}: git commit failed for %s — changes are staged but not committed\n" "$id"
      fi
    fi
  fi

  release_lock
  printf "${GREEN}Resolved${NC} %s\n" "$id"

  # Checkpoint: run full test suite every 5 resolved issues
  local done_count
  done_count=$(CP_ISSUES_FILE="$ISSUES_FILE" python3 -c "
import json, os
with open(os.environ['CP_ISSUES_FILE']) as f:
    data = json.load(f)
print(sum(1 for i in data['issues'] if i['status'] == 'done'))
")
  if [ $((done_count % 5)) -eq 0 ] && [ "$done_count" -gt 0 ]; then
    printf "${CYAN}Checkpoint${NC}: %d issues resolved — running full verification...\n" "$done_count"
    "$SCRIPT_DIR/verify.sh" || {
      printf "${RED}CHECKPOINT FAILED${NC}: Full verification failed after %d resolved issues.\n" "$done_count"
      printf "Review the last 5 commits for regressions.\n"
    }
  fi
}

cmd_fail() {
  if [ $# -lt 1 ]; then
    printf "${RED}ERROR${NC}: fail requires at least 1 argument: <ISS-N> [reason]\n" >&2
    exit 1
  fi
  local id="$1"
  local reason="${2:-unspecified}"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Revert tracked file changes only. Do NOT run git clean — it would
  # destroy untracked user files (new files, scratch work, etc.).
  # Only remove files that the agent created during this attempt by
  # reverting tracked changes and unstaging new files.
  if git rev-parse --git-dir &>/dev/null; then
    git checkout -- ':!.codeperfect' 2>/dev/null || true
    # Unstage any newly staged files, but do NOT delete them
    git reset HEAD -- ':!.codeperfect' 2>/dev/null || true
    printf "${YELLOW}Reverted${NC} tracked file changes (untracked files preserved)\n"
  fi

  local fail_result=0
  CP_ISSUES_FILE="$ISSUES_FILE" CP_ID="$id" CP_REASON="$reason" \
  CP_TIMESTAMP="$timestamp" CP_MAX="$MAX_ATTEMPTS" \
  python3 -c "
import json, os, sys
issues_file = os.environ['CP_ISSUES_FILE']
issue_id = os.environ['CP_ID']
reason = os.environ['CP_REASON']
timestamp = os.environ['CP_TIMESTAMP']
max_attempts = int(os.environ['CP_MAX'])
with open(issues_file) as f:
    data = json.load(f)
found = False
for issue in data['issues']:
    if issue['id'] == issue_id:
        found = True
        if issue['status'] not in ('in_progress', 'open'):
            print(f'ERROR: {issue_id} has status \"{issue[\"status\"]}\" — cannot fail')
            sys.exit(1)
        issue['attempts'] += 1
        issue['history'].append({
            'attempt': issue['attempts'],
            'action': 'failed',
            'reason': reason,
            'timestamp': timestamp
        })
        if issue['attempts'] >= max_attempts:
            issue['status'] = 'deferred'
            issue['history'].append({
                'attempt': issue['attempts'],
                'action': 'auto-deferred',
                'reason': f'max attempts ({max_attempts}) reached',
                'timestamp': timestamp
            })
            print(f'DEFERRED: {issue_id} exhausted all {max_attempts} attempts')
        else:
            issue['status'] = 'open'
            print(f'REQUEUED: {issue_id} (attempt {issue[\"attempts\"]}/{max_attempts})')
        break
if not found:
    print(f'ERROR: {issue_id} not found')
    sys.exit(1)
with open(issues_file, 'w') as f:
    json.dump(data, f, indent=2)
" || fail_result=$?
  release_lock
  [ "$fail_result" -ne 0 ] && exit "$fail_result"
}

cmd_status() {
  ensure_issues_file

  # Track and enforce max iterations: max(10, issue_count * 3)
  local iteration=0
  if [ -f "$ITERATION_FILE" ]; then
    iteration=$(cat "$ITERATION_FILE" 2>/dev/null || echo "0")
  fi
  iteration=$((iteration + 1))
  echo "$iteration" > "$ITERATION_FILE"

  local issue_count
  issue_count=$(CP_ISSUES_FILE="$ISSUES_FILE" python3 -c "
import json, os
with open(os.environ['CP_ISSUES_FILE']) as f:
    print(len(json.load(f)['issues']))
" 2>/dev/null || echo "0")

  local max_iterations=10
  local computed=$((issue_count * 3))
  if [ "$computed" -gt "$max_iterations" ]; then
    max_iterations=$computed
  fi

  if [ "$iteration" -gt "$max_iterations" ]; then
    printf "${RED}ERROR${NC}: Max iterations (%d) exceeded. Force-stopping loop.\n" "$max_iterations"
    printf "       Remaining issues will be reported as incomplete.\n"
    exit 2
  fi
  printf "${CYAN}Iteration${NC} %d / %d max\n" "$iteration" "$max_iterations"

  CP_ISSUES_FILE="$ISSUES_FILE" python3 -c "
import json, os, sys
with open(os.environ['CP_ISSUES_FILE']) as f:
    data = json.load(f)

issues = data['issues']
total = len(issues)
by_status = {}
for i in issues:
    s = i['status']
    by_status[s] = by_status.get(s, 0) + 1

open_count = by_status.get('open', 0)
in_progress = by_status.get('in_progress', 0)
done = by_status.get('done', 0)
deferred = by_status.get('deferred', 0)
remaining = open_count + in_progress

print(f'Total: {total}  |  OPEN: {open_count}  |  IN_PROGRESS: {in_progress}  |  DONE: {done}  |  DEFERRED: {deferred}')
print(f'Remaining: {remaining}')

if remaining > 0:
    print()
    print('Next issues to resolve:')
    severity_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
    pending = sorted(
        [i for i in issues if i['status'] in ('open', 'in_progress')],
        key=lambda x: severity_order.get(x['severity'], 99)
    )
    for i in pending[:5]:
        print(f\"  {i['id']} [{i['severity']}] {i['file']}:{i['line']} — {i['description']} (attempts: {i['attempts']})\")
    sys.exit(1)  # Issues remain — loop must continue
else:
    sys.exit(0)  # All done — loop can exit
"
}

cmd_report() {
  ensure_issues_file
  local report_file="$STATE_DIR/resolution-report.md"

  CP_ISSUES_FILE="$ISSUES_FILE" python3 -c "
import json, os
with open(os.environ['CP_ISSUES_FILE']) as f:
    data = json.load(f)

issues = data['issues']
done = [i for i in issues if i['status'] == 'done']
deferred = [i for i in issues if i['status'] == 'deferred']

lines = ['# Resolution Loop Report', '']
lines.append(f'**Total issues:** {len(issues)}')
lines.append(f'**Resolved:** {len(done)}')
lines.append(f'**Deferred:** {len(deferred)}')
lines.append('')

if done:
    lines.append('## Resolved Issues')
    lines.append('')
    lines.append('| ID | Severity | File | Description | Attempts |')
    lines.append('|----|----------|------|-------------|----------|')
    for i in sorted(done, key=lambda x: x['id']):
        lines.append(f\"| {i['id']} | {i['severity']} | {i['file']}:{i['line']} | {i['description']} | {i['attempts']} |\")
    lines.append('')

if deferred:
    lines.append('## Deferred Issues')
    lines.append('')
    lines.append('| ID | Severity | File | Description | Reason |')
    lines.append('|----|----------|------|-------------|--------|')
    for i in sorted(deferred, key=lambda x: x['id']):
        reasons = [h.get('reason','') for h in i.get('history',[]) if h.get('action') == 'failed']
        reason_str = '; '.join(reasons[-3:]) if reasons else 'max attempts'
        lines.append(f\"| {i['id']} | {i['severity']} | {i['file']}:{i['line']} | {i['description']} | {reason_str} |\")
    lines.append('')

print('\n'.join(lines))
" > "$report_file"

  printf "${GREEN}Report${NC} written to %s\n" "$report_file"
  cat "$report_file"
}

# Dispatch
case "${1:-help}" in
  init)    shift; cmd_init "$@" ;;
  scan)    shift; cmd_scan "$@" ;;
  add)     shift; cmd_add "$@" ;;
  start)   shift; cmd_start "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  fail)    shift; cmd_fail "$@" ;;
  status)  cmd_status ;;
  report)  cmd_report ;;
  help|*)
    printf "Usage: scripts/resolution-loop.sh <command> [args...]\n\n"
    printf "Commands:\n"
    printf "  init [target]                          Initialize issue ledger\n"
    printf "  scan [target]                          Prompt agent to scan for issues\n"
    printf "  add <file> <line> <severity> <desc>    Add an issue to the ledger\n"
    printf "  start <ISS-N>                          Mark issue as in-progress (acquires lock)\n"
    printf "  resolve <ISS-N>                        Mark issue as done (auto-commits, releases lock)\n"
    printf "  fail <ISS-N> <reason>                  Revert changes, record failure (releases lock)\n"
    printf "  status                                 Show progress (exit 0=done, 1=continue)\n"
    printf "  report                                 Generate final report\n"
    ;;
esac
