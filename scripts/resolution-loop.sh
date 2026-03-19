#!/usr/bin/env bash
# Resolution loop — mechanical enforcement of the fix-verify-decide cycle.
# Manages the issue ledger, enforces revert-on-failure, blocks exit until clean.
# Usage: scripts/resolution-loop.sh <command> [args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

check_python3
check_git

MAX_ATTEMPTS=3

# --- File management ---

ensure_issues_file() {
  if [ ! -f "$ISSUES_FILE" ]; then
    ensure_state_dir
    printf '{"version":1,"created":"%s","target":".","issues":[]}\n' "$(utc_timestamp)" > "$ISSUES_FILE"
  fi
}

# --- Lock management ---

cleanup_lock() {
  if [ -d "$LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(<"$LOCK_FILE/pid" 2>/dev/null || echo "")
    if [ "$lock_pid" = "$$" ]; then
      rm -rf "$LOCK_FILE"
    fi
  fi
}

acquire_lock() {
  ensure_state_dir
  if [ -d "$LOCK_FILE" ]; then
    # Pure-bash check: is any issue in_progress?
    local has_in_progress=false
    if [ -f "$ISSUES_FILE" ]; then
      json_has_status "$ISSUES_FILE" "in_progress" && has_in_progress=true
    fi
    if [ "$has_in_progress" = "true" ]; then
      die "Lock held — an issue is already in_progress. Resolve or fail it first."
    fi
    warn_msg "Stale lock found (no in_progress issues). Removing."
    rm -rf "$LOCK_FILE"
  fi
  if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    die "Failed to acquire lock (race condition). Retry."
  fi
  echo $$ > "$LOCK_FILE/pid"
  trap 'cleanup_lock; exit 130' INT
  trap 'cleanup_lock; exit 143' TERM
}

release_lock() {
  rm -rf "$LOCK_FILE"
}

# --- Commands ---

cmd_init() {
  local target="${1:-.}"
  ensure_state_dir
  local ts
  ts="$(utc_timestamp)"
  printf '{"version":1,"created":"%s","target":"%s","issues":[]}\n' "$ts" "$target" > "$ISSUES_FILE"
  echo "0" > "$ITERATION_FILE"
  ok_msg "Initialized issue ledger at $ISSUES_FILE for target: $target"
}

cmd_add() {
  if [ $# -lt 4 ]; then
    die "add requires 4 arguments: <file> <line> <severity> <description>"
  fi
  local file="$1" line="$2" severity="$3" description="$4"
  ensure_issues_file

  # Pure-bash hot path for next ID
  local id
  id=$(json_next_issue_id "$ISSUES_FILE")

  CP_ISSUES_FILE="$ISSUES_FILE" CP_ID="$id" CP_FILE="$file" \
  CP_LINE="$line" CP_SEVERITY="$severity" CP_DESC="$description" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os
issues_file = os.environ['CP_ISSUES_FILE']
data, _ = safe_json_load(issues_file)
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
atomic_json_write_with_backup(issues_file, data)
"
  printf "${GREEN}Added${NC} %s [%s] %s:%s — %s\n" "$id" "$severity" "$file" "$line" "$description"
}

cmd_add_batch() {
  # Batch add: reads issues from stdin, one per line as: file|line|severity|description
  # Avoids N python3 invocations for N issues.
  ensure_issues_file

  local batch_input
  batch_input=$(</dev/stdin)
  [ -z "$batch_input" ] && die "add-batch: no input on stdin"

  CP_ISSUES_FILE="$ISSUES_FILE" CP_BATCH="$batch_input" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os, sys
issues_file = os.environ['CP_ISSUES_FILE']
data, _ = safe_json_load(issues_file)
existing_ids = [int(i['id'].replace('ISS-','')) for i in data['issues'] if i['id'].startswith('ISS-')]
next_num = max(existing_ids) + 1 if existing_ids else 1
added = 0
for line in os.environ['CP_BATCH'].strip().split('\n'):
    parts = line.split('|', 3)
    if len(parts) < 4:
        print(f'WARN: Skipping malformed line: {line}', file=sys.stderr)
        continue
    file_, line_num, severity, desc = parts
    issue_id = f'ISS-{next_num}'
    data['issues'].append({
        'id': issue_id,
        'file': file_.strip(),
        'line': int(line_num.strip()),
        'severity': severity.strip(),
        'description': desc.strip(),
        'status': 'open',
        'attempts': 0,
        'history': []
    })
    print(f'Added {issue_id} [{severity.strip()}] {file_.strip()}:{line_num.strip()} — {desc.strip()}')
    next_num += 1
    added += 1
atomic_json_write_with_backup(issues_file, data)
print(f'Batch complete: {added} issues added')
"
}

cmd_scan() {
  local target="${1:-.}"
  ensure_state_dir
  ensure_issues_file
  info_msg "Scanning $target for issues..."
  printf "${YELLOW}NOTE${NC}: The agent must populate the ledger by calling 'add' for each issue found.\n"
  printf "       Run: scripts/resolution-loop.sh add <file> <line> <severity> <description>\n"
  printf "       Or batch: echo 'file|line|sev|desc' | scripts/resolution-loop.sh add-batch\n"
}

cmd_start() {
  if [ $# -lt 1 ]; then
    die "start requires 1 argument: <ISS-N>"
  fi
  local id="$1"
  acquire_lock

  local start_result=0
  CP_ISSUES_FILE="$ISSUES_FILE" CP_ID="$id" CP_MAX="$MAX_ATTEMPTS" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os, sys
issues_file = os.environ['CP_ISSUES_FILE']
issue_id = os.environ['CP_ID']
max_attempts = int(os.environ['CP_MAX'])
data, _ = safe_json_load(issues_file)
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
            atomic_json_write_with_backup(issues_file, data)
            sys.exit(1)
        issue['status'] = 'in_progress'
        found = True
        break
if not found:
    print(f'ERROR: {issue_id} not found')
    sys.exit(1)
atomic_json_write_with_backup(issues_file, data)
" || start_result=$?

  if [ "$start_result" -ne 0 ]; then
    release_lock
    exit 1
  fi
  info_msg "Started $id"
}

cmd_resolve() {
  if [ $# -lt 1 ]; then
    die "resolve requires 1 argument: <ISS-N>"
  fi
  local id="$1"
  local timestamp
  timestamp="$(utc_timestamp)"

  CP_ISSUES_FILE="$ISSUES_FILE" CP_ID="$id" CP_TIMESTAMP="$timestamp" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os, sys
issues_file = os.environ['CP_ISSUES_FILE']
issue_id = os.environ['CP_ID']
timestamp = os.environ['CP_TIMESTAMP']
data, _ = safe_json_load(issues_file)
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
        # Print description for commit message
        print(f'DESC:{issue[\"description\"]}')
        break
if not found:
    print(f'ERROR: {issue_id} not found')
    sys.exit(1)
atomic_json_write_with_backup(issues_file, data)
" > /tmp/.cp_resolve_out 2>&1 || { release_lock; cat /tmp/.cp_resolve_out; exit 1; }

  local resolve_output
  resolve_output=$(<"/tmp/.cp_resolve_out")

  # Check for errors
  if [[ "$resolve_output" == ERROR:* ]]; then
    printf "%s\n" "$resolve_output"
    release_lock
    exit 1
  fi

  # Auto-commit the fix
  if git rev-parse --git-dir &>/dev/null; then
    # Extract description from python output (DESC:...)
    local desc=""
    if [[ "$resolve_output" == DESC:* ]]; then
      desc="${resolve_output#DESC:}"
    fi
    git add --update -- ':!.codeperfect'
    if ! git diff --cached --quiet 2>/dev/null; then
      if ! printf 'fix(codeperfect): %s — %s' "$id" "$desc" | git commit -F -; then
        warn_msg "git commit failed for $id — changes are staged but not committed"
      fi
    fi
  fi

  release_lock
  ok_msg "Resolved $id"

  # Checkpoint: run full test suite every 5 resolved issues (pure-bash count)
  local done_count
  done_count=$(json_count_by_status "$ISSUES_FILE" "done")
  if [ $((done_count % 5)) -eq 0 ] && [ "$done_count" -gt 0 ]; then
    info_msg "Checkpoint: $done_count issues resolved — running full verification..."
    "$SCRIPT_DIR/verify.sh" || {
      printf "${RED}CHECKPOINT FAILED${NC}: Full verification failed after %d resolved issues.\n" "$done_count"
      printf "Review the last 5 commits for regressions.\n"
    }
  fi
}

cmd_fail() {
  if [ $# -lt 1 ]; then
    die "fail requires at least 1 argument: <ISS-N> [reason]"
  fi
  local id="$1"
  local reason="${2:-unspecified}"
  local timestamp
  timestamp="$(utc_timestamp)"

  # Validate issue status BEFORE reverting (pure-bash pre-check for speed,
  # then authoritative python check).
  ensure_issues_file
  local status_check=0
  CP_ISSUES_FILE="$ISSUES_FILE" CP_ID="$id" python3 -c "
import json, os, sys
with open(os.environ['CP_ISSUES_FILE']) as f:
    data = json.load(f)
for issue in data['issues']:
    if issue['id'] == os.environ['CP_ID']:
        if issue['status'] not in ('in_progress', 'open'):
            print(f'ERROR: {os.environ[\"CP_ID\"]} has status \"{issue[\"status\"]}\" — cannot fail')
            sys.exit(1)
        sys.exit(0)
print(f'ERROR: {os.environ[\"CP_ID\"]} not found')
sys.exit(1)
" || status_check=$?

  if [ "$status_check" -ne 0 ]; then
    printf "${RED}Skipping revert${NC} — issue status does not permit fail operation.\n"
    release_lock
    exit 1
  fi

  # Revert tracked file changes only.
  if git rev-parse --git-dir &>/dev/null; then
    git checkout -- ':!.codeperfect' 2>/dev/null || true
    git reset HEAD -- ':!.codeperfect' 2>/dev/null || true
    warn_msg "Reverted tracked file changes (untracked files preserved)"
  fi

  CP_ISSUES_FILE="$ISSUES_FILE" CP_ID="$id" CP_REASON="$reason" \
  CP_TIMESTAMP="$timestamp" CP_MAX="$MAX_ATTEMPTS" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os, sys
issues_file = os.environ['CP_ISSUES_FILE']
issue_id = os.environ['CP_ID']
reason = os.environ['CP_REASON']
timestamp = os.environ['CP_TIMESTAMP']
max_attempts = int(os.environ['CP_MAX'])
data, _ = safe_json_load(issues_file)
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
atomic_json_write_with_backup(issues_file, data)
"
  release_lock
}

cmd_status() {
  ensure_issues_file

  # Track iteration count (pure bash — no python needed)
  local iteration=0
  if [ -f "$ITERATION_FILE" ]; then
    iteration=$(<"$ITERATION_FILE" 2>/dev/null || echo "0")
  fi
  iteration=$((iteration + 1))
  echo "$iteration" > "$ITERATION_FILE"

  # Pure-bash issue count for iteration cap
  local issue_count
  issue_count=$(json_count_issues "$ISSUES_FILE")

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

  # Status display still needs python for sorting/formatting
  CP_ISSUES_FILE="$ISSUES_FILE" python3 -c "
import json, os, sys
data, corrupted = __import__('builtins').__dict__.get('safe_json_load', lambda f: (json.load(open(f)), False))(os.environ['CP_ISSUES_FILE']) if False else (json.load(open(os.environ['CP_ISSUES_FILE'])), False)

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
    sys.exit(1)
else:
    sys.exit(0)
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

  ok_msg "Report written to $report_file"
  cat "$report_file"
}

# --- Dispatch ---
case "${1:-help}" in
  init)      shift; cmd_init "$@" ;;
  scan)      shift; cmd_scan "$@" ;;
  add)       shift; cmd_add "$@" ;;
  add-batch) shift; cmd_add_batch "$@" ;;
  start)     shift; cmd_start "$@" ;;
  resolve)   shift; cmd_resolve "$@" ;;
  fail)      shift; cmd_fail "$@" ;;
  status)    cmd_status ;;
  report)    cmd_report ;;
  help|*)
    cat <<'USAGE'
Usage: scripts/resolution-loop.sh <command> [args...]

Commands:
  init [target]                          Initialize issue ledger
  scan [target]                          Prompt agent to scan for issues
  add <file> <line> <severity> <desc>    Add an issue to the ledger
  add-batch                              Add issues from stdin (file|line|sev|desc per line)
  start <ISS-N>                          Mark issue as in-progress (acquires lock)
  resolve <ISS-N>                        Mark issue as done (auto-commits, releases lock)
  fail <ISS-N> <reason>                  Revert changes, record failure (releases lock)
  status                                 Show progress (exit codes below)
  report                                 Generate final report

Exit codes for 'status':
  0  All issues resolved or deferred — loop can exit
  1  Issues remain — loop MUST continue
  2  Max iterations exceeded — loop force-stopped
USAGE
    ;;
esac
