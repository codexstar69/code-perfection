#!/usr/bin/env bash
# Resolution loop — mechanical enforcement of the fix-verify-decide cycle.
# Manages the issue ledger, enforces revert-on-failure, blocks exit until clean.
# Usage: scripts/resolution-loop.sh <command> [args...]
set -euo pipefail

STATE_DIR=".codeperfect"
ISSUES_FILE="$STATE_DIR/issues.json"
LOCK_FILE="$STATE_DIR/fix.lock"
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
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# Generate next issue ID
next_id() {
  local max_id
  max_id=$(python3 -c "
import json, sys
with open('$ISSUES_FILE') as f:
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
  printf "${GREEN}Initialized${NC} issue ledger at %s for target: %s\n" "$ISSUES_FILE" "$target"
}

cmd_add() {
  local file="$1"
  local line="$2"
  local severity="$3"
  local description="$4"
  ensure_issues_file

  local id
  id=$(next_id)

  python3 -c "
import json, sys
with open('$ISSUES_FILE') as f:
    data = json.load(f)
data['issues'].append({
    'id': '$id',
    'file': '$file',
    'line': int('$line'),
    'severity': '$severity',
    'description': $(python3 -c "import json; print(json.dumps('$description'))"),
    'status': 'open',
    'attempts': 0,
    'history': []
})
with open('$ISSUES_FILE', 'w') as f:
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
  local id="$1"
  acquire_lock

  python3 -c "
import json
with open('$ISSUES_FILE') as f:
    data = json.load(f)
found = False
for issue in data['issues']:
    if issue['id'] == '$id':
        if issue['status'] == 'deferred':
            print('ERROR: $id is DEFERRED — cannot restart')
            exit(1)
        if issue['attempts'] >= $MAX_ATTEMPTS:
            print('ERROR: $id has exhausted all $MAX_ATTEMPTS attempts — auto-deferring')
            issue['status'] = 'deferred'
            issue['history'].append({'attempt': issue['attempts'], 'action': 'auto-deferred', 'reason': 'max attempts reached'})
            with open('$ISSUES_FILE', 'w') as f:
                json.dump(data, f, indent=2)
            exit(1)
        issue['status'] = 'in_progress'
        found = True
        break
if not found:
    print('ERROR: $id not found')
    exit(1)
with open('$ISSUES_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
  printf "${CYAN}Started${NC} %s\n" "$id"
}

cmd_resolve() {
  local id="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  python3 -c "
import json
with open('$ISSUES_FILE') as f:
    data = json.load(f)
for issue in data['issues']:
    if issue['id'] == '$id':
        issue['status'] = 'done'
        issue['attempts'] += 1
        issue['history'].append({
            'attempt': issue['attempts'],
            'action': 'resolved',
            'timestamp': '$timestamp'
        })
        break
with open('$ISSUES_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"

  # Auto-commit the fix
  if git rev-parse --git-dir &>/dev/null; then
    local desc
    desc=$(python3 -c "
import json
with open('$ISSUES_FILE') as f:
    data = json.load(f)
for issue in data['issues']:
    if issue['id'] == '$id':
        print(issue['description'])
        break
")
    git add --all -- ':!.codeperfect'
    git commit -m "fix(codeperfect): $id — $desc" --allow-empty-message 2>/dev/null || true
  fi

  release_lock
  printf "${GREEN}Resolved${NC} %s\n" "$id"

  # Checkpoint: run full test suite every 5 resolved issues
  local done_count
  done_count=$(python3 -c "
import json
with open('$ISSUES_FILE') as f:
    data = json.load(f)
print(sum(1 for i in data['issues'] if i['status'] == 'done'))
")
  if [ $((done_count % 5)) -eq 0 ] && [ "$done_count" -gt 0 ]; then
    printf "${CYAN}Checkpoint${NC}: %d issues resolved — running full verification...\n" "$done_count"
    scripts/verify.sh || {
      printf "${RED}CHECKPOINT FAILED${NC}: Full verification failed after %d resolved issues.\n" "$done_count"
      printf "Review the last 5 commits for regressions.\n"
    }
  fi
}

cmd_fail() {
  local id="$1"
  local reason="${2:-unspecified}"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Revert all uncommitted changes
  if git rev-parse --git-dir &>/dev/null; then
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    printf "${YELLOW}Reverted${NC} all uncommitted changes\n"
  fi

  python3 -c "
import json
with open('$ISSUES_FILE') as f:
    data = json.load(f)
for issue in data['issues']:
    if issue['id'] == '$id':
        issue['attempts'] += 1
        issue['history'].append({
            'attempt': issue['attempts'],
            'action': 'failed',
            'reason': $(python3 -c "import json; print(json.dumps('$reason'))"),
            'timestamp': '$timestamp'
        })
        if issue['attempts'] >= $MAX_ATTEMPTS:
            issue['status'] = 'deferred'
            issue['history'].append({
                'attempt': issue['attempts'],
                'action': 'auto-deferred',
                'reason': 'max attempts ($MAX_ATTEMPTS) reached',
                'timestamp': '$timestamp'
            })
            print('DEFERRED: $id exhausted all $MAX_ATTEMPTS attempts')
        else:
            issue['status'] = 'open'
            print('REQUEUED: $id (attempt ' + str(issue['attempts']) + '/$MAX_ATTEMPTS)')
        break
with open('$ISSUES_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
  release_lock
}

cmd_status() {
  ensure_issues_file

  python3 -c "
import json, sys
with open('$ISSUES_FILE') as f:
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

  python3 -c "
import json
with open('$ISSUES_FILE') as f:
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
