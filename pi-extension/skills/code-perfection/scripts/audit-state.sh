#!/usr/bin/env bash
# Audit state manager — tracks domain-scoped audit progress.
# Prevents re-scanning done domains, enforces one-domain-at-a-time, manages resume.
# Usage: scripts/audit-state.sh <command> [args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

check_python3

# --- Commands ---

cmd_init() {
  local target="${1:-.}"
  ensure_state_dir

  if [ ! -f "$TRIAGE_FILE" ]; then
    die "Run scripts/triage.sh first to generate $TRIAGE_FILE"
  fi

  local timestamp
  timestamp="$(utc_timestamp)"
  CP_TRIAGE="$TRIAGE_FILE" CP_TARGET="$target" CP_AUDIT_STATE="$AUDIT_STATE" \
  CP_TIMESTAMP="$timestamp" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os

with open(os.environ['CP_TRIAGE']) as f:
    triage = json.load(f)

state = {
    'version': 1,
    'target': os.environ['CP_TARGET'],
    'created': os.environ['CP_TIMESTAMP'],
    'triage': os.environ['CP_TRIAGE'],
    'domains': {},
    'boundaries': {},
    'total_resolved': 0,
    'total_deferred': 0,
    'last_updated': os.environ['CP_TIMESTAMP']
}

for domain in triage.get('domains', []):
    name = domain['name']
    state['domains'][name] = {
        'status': 'pending',
        'tier': domain.get('tier', 'medium'),
        'file_count': domain.get('file_count', 0),
        'issues_found': 0,
        'issues_resolved': 0,
        'issues_deferred': 0
    }

atomic_json_write_with_backup(os.environ['CP_AUDIT_STATE'], state)
print(f'Initialized audit state: {len(state[\"domains\"])} domains')
"
  ok_msg "Audit state initialized at $AUDIT_STATE"
}

cmd_status() {
  if [ ! -f "$AUDIT_STATE" ]; then
    die "No audit state found. Run: scripts/audit-state.sh init <target>"
  fi

  CP_AUDIT_STATE="$AUDIT_STATE" python3 -c "
import json, os

with open(os.environ['CP_AUDIT_STATE']) as f:
    state = json.load(f)

domains = state['domains']
boundaries = state.get('boundaries', {})
tier_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}

print('=== Audit Progress ===')
print()

by_status = {}
for name, d in sorted(domains.items(), key=lambda x: (tier_order.get(x[1].get('tier','low'), 99), x[0])):
    s = d['status']
    by_status[s] = by_status.get(s, 0) + 1
    print(f'  [{d.get(\"tier\",\"?\"):>8}] {name:30s} {s:12s}  files={d[\"file_count\"]}  resolved={d[\"issues_resolved\"]}  deferred={d[\"issues_deferred\"]}')

print()
print(f'Domains: {by_status.get(\"done\",0)} done / {by_status.get(\"in_progress\",0)} active / {by_status.get(\"pending\",0)} pending')
print(f'Total resolved: {state[\"total_resolved\"]}  |  Total deferred: {state[\"total_deferred\"]}')

if boundaries:
    b_done = sum(1 for b in boundaries.values() if b['status'] == 'done')
    b_pending = sum(1 for b in boundaries.values() if b['status'] != 'done')
    print(f'Boundaries: {b_done} done / {b_pending} pending')
"
}

cmd_next_domain() {
  if [ ! -f "$AUDIT_STATE" ]; then
    die "No audit state found."
  fi

  # Pure-bash fast path: check for in_progress first
  if json_has_status "$AUDIT_STATE" "in_progress"; then
    # Need python to extract the domain name
    CP_AUDIT_STATE="$AUDIT_STATE" python3 -c "
import json, os
with open(os.environ['CP_AUDIT_STATE']) as f:
    state = json.load(f)
for name, d in state['domains'].items():
    if d['status'] == 'in_progress':
        print(f'RESUME: {name} (already in progress)')
        break
"
    return 0
  fi

  # Check if any pending domains exist (pure bash)
  if ! json_has_status "$AUDIT_STATE" "pending"; then
    echo "ALL_DOMAINS_DONE"
    return 0
  fi

  # Need python for tier-priority sorting
  CP_AUDIT_STATE="$AUDIT_STATE" python3 -c "
import json, os
with open(os.environ['CP_AUDIT_STATE']) as f:
    state = json.load(f)
tier_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
pending = [(name, d) for name, d in state['domains'].items() if d['status'] == 'pending']
pending.sort(key=lambda x: (tier_order.get(x[1].get('tier','low'), 99), x[0]))
if pending:
    print(f'NEXT: {pending[0][0]} (tier: {pending[0][1].get(\"tier\",\"unknown\")})')
"
}

cmd_start_domain() {
  if [ $# -lt 1 ]; then
    die "start-domain requires 1 argument: <name>"
  fi
  local name="$1"
  local timestamp
  timestamp="$(utc_timestamp)"

  CP_AUDIT_STATE="$AUDIT_STATE" CP_NAME="$name" CP_TIMESTAMP="$timestamp" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os, sys
audit_state = os.environ['CP_AUDIT_STATE']
domain_name = os.environ['CP_NAME']
timestamp = os.environ['CP_TIMESTAMP']
data, _ = safe_json_load(audit_state)

# Check no other domain is in_progress
for dname, d in data['domains'].items():
    if d['status'] == 'in_progress' and dname != domain_name:
        print(f'ERROR: Domain {dname} is already in_progress. Complete it first.')
        sys.exit(1)

if domain_name not in data['domains']:
    print(f'ERROR: Domain {domain_name} not found in audit state')
    sys.exit(1)

if data['domains'][domain_name]['status'] == 'done':
    print(f'ERROR: Domain {domain_name} is already done. Use --force to re-audit.')
    sys.exit(1)

data['domains'][domain_name]['status'] = 'in_progress'
data['last_updated'] = timestamp
atomic_json_write_with_backup(audit_state, data)
print(f'Started domain: {domain_name}')
"
  info_msg "Started domain: $name"
  mkdir -p "$STATE_DIR/domains/$name"
}

cmd_complete_domain() {
  if [ $# -lt 1 ]; then
    die "complete-domain requires 1 argument: <name>"
  fi
  local name="$1"

  # Read resolution loop results (pure bash for basic counts)
  local issues_found=0 issues_resolved=0 issues_deferred=0

  if [ -f "$ISSUES_FILE" ]; then
    issues_found=$(json_count_issues "$ISSUES_FILE")
    issues_resolved=$(json_count_by_status "$ISSUES_FILE" "done")
    issues_deferred=$(json_count_by_status "$ISSUES_FILE" "deferred")
    # Archive domain issues
    cp "$ISSUES_FILE" "$STATE_DIR/domains/$name/issues.json" 2>/dev/null || true
  fi

  local timestamp
  timestamp="$(utc_timestamp)"
  CP_AUDIT_STATE="$AUDIT_STATE" CP_NAME="$name" CP_TIMESTAMP="$timestamp" \
  CP_FOUND="$issues_found" CP_RESOLVED="$issues_resolved" CP_DEFERRED="$issues_deferred" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os, sys
audit_state = os.environ['CP_AUDIT_STATE']
domain_name = os.environ['CP_NAME']
data, _ = safe_json_load(audit_state)

if domain_name not in data['domains']:
    print(f'ERROR: Domain {domain_name} not found in audit state')
    sys.exit(1)
if data['domains'][domain_name]['status'] != 'in_progress':
    print(f'ERROR: Domain {domain_name} has status \"{data[\"domains\"][domain_name][\"status\"]}\" — must be in_progress to complete')
    sys.exit(1)

data['domains'][domain_name]['status'] = 'done'
data['domains'][domain_name]['issues_found'] = int(os.environ['CP_FOUND'])
data['domains'][domain_name]['issues_resolved'] = int(os.environ['CP_RESOLVED'])
data['domains'][domain_name]['issues_deferred'] = int(os.environ['CP_DEFERRED'])
data['total_resolved'] = sum(d['issues_resolved'] for d in data['domains'].values())
data['total_deferred'] = sum(d['issues_deferred'] for d in data['domains'].values())
data['last_updated'] = os.environ['CP_TIMESTAMP']
atomic_json_write_with_backup(audit_state, data)
"
  printf "${GREEN}Completed${NC} domain: %s (found=%d resolved=%d deferred=%d)\n" \
    "$name" "$issues_found" "$issues_resolved" "$issues_deferred"
}

cmd_find_boundaries() {
  local target="${1:-.}"

  if [ ! -f "$AUDIT_STATE" ]; then
    die "No audit state found."
  fi

  info_msg "Discovering cross-domain boundaries in $target..."

  local timestamp
  timestamp="$(utc_timestamp)"
  CP_AUDIT_STATE="$AUDIT_STATE" CP_TARGET="$target" CP_TIMESTAMP="$timestamp" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os, re

audit_state = os.environ['CP_AUDIT_STATE']
target = os.environ['CP_TARGET']
timestamp = os.environ['CP_TIMESTAMP']

data, _ = safe_json_load(audit_state)
domain_names = list(data['domains'].keys())
boundaries = {}

# Pre-compile patterns for each domain pair (scalability: avoid recompiling per file)
domain_patterns = {}
for other in domain_names:
    domain_patterns[other] = re.compile(
        rf'(?:from\s+[\"\\x27].*{re.escape(other)}|import\s+.*[\"\\x27].*{re.escape(other)}|require\([\"\\x27].*{re.escape(other)})'
    )

SOURCE_EXTS = {'.ts', '.tsx', '.js', '.jsx', '.py', '.go', '.rs'}
SKIP_DIRS = {'node_modules', 'dist', 'build', '.git', '__pycache__', '.venv', 'vendor', '.next', 'coverage', '.codeperfect'}

for root, dirs, files in os.walk(target):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
    for fname in files:
        if os.path.splitext(fname)[1] not in SOURCE_EXTS:
            continue
        fpath = os.path.join(root, fname)
        try:
            with open(fpath, 'r', errors='ignore') as f:
                content = f.read()
        except Exception:
            continue

        # Find which domain this file belongs to
        file_domain = None
        for d in domain_names:
            if fpath.startswith(os.path.join(target, d)) or ('/' + d + '/') in fpath:
                file_domain = d
                break
        if not file_domain:
            continue

        # Check for cross-domain imports
        for other in domain_names:
            if other == file_domain:
                continue
            if domain_patterns[other].search(content):
                key = '-'.join(sorted([file_domain, other]))
                if key not in boundaries:
                    boundaries[key] = {'status': 'pending', 'files': []}
                if fpath not in boundaries[key]['files']:
                    boundaries[key]['files'].append(fpath)

data['boundaries'] = boundaries
data['last_updated'] = timestamp
atomic_json_write_with_backup(audit_state, data)

print(f'Found {len(boundaries)} boundary pairs:')
for key, b in sorted(boundaries.items()):
    print(f'  {key}: {len(b[\"files\"])} boundary files')
" 2>/dev/null || warn_msg "Boundary detection encountered an error"
}

cmd_start_boundary() {
  if [ $# -lt 1 ]; then
    die "start-boundary requires 1 argument: <pair>"
  fi
  local pair="$1"
  local timestamp
  timestamp="$(utc_timestamp)"
  CP_AUDIT_STATE="$AUDIT_STATE" CP_PAIR="$pair" CP_TIMESTAMP="$timestamp" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os, sys
audit_state = os.environ['CP_AUDIT_STATE']
pair = os.environ['CP_PAIR']
data, _ = safe_json_load(audit_state)
if pair not in data.get('boundaries', {}):
    print(f'ERROR: Boundary {pair} not found')
    sys.exit(1)
data['boundaries'][pair]['status'] = 'in_progress'
data['last_updated'] = os.environ['CP_TIMESTAMP']
atomic_json_write_with_backup(audit_state, data)
"
  info_msg "Started boundary audit: $pair"
}

cmd_complete_boundary() {
  if [ $# -lt 1 ]; then
    die "complete-boundary requires 1 argument: <pair>"
  fi
  local pair="$1"
  local timestamp
  timestamp="$(utc_timestamp)"
  CP_AUDIT_STATE="$AUDIT_STATE" CP_PAIR="$pair" CP_TIMESTAMP="$timestamp" \
  python3 -c "
${ATOMIC_WRITE_PY}
import json, os, sys
audit_state = os.environ['CP_AUDIT_STATE']
pair = os.environ['CP_PAIR']
data, _ = safe_json_load(audit_state)
if pair not in data.get('boundaries', {}):
    print(f'ERROR: Boundary {pair} not found')
    sys.exit(1)
if data['boundaries'][pair]['status'] != 'in_progress':
    print(f'ERROR: Boundary {pair} has status \"{data[\"boundaries\"][pair][\"status\"]}\" — must be in_progress to complete')
    sys.exit(1)
data['boundaries'][pair]['status'] = 'done'
data['last_updated'] = os.environ['CP_TIMESTAMP']
atomic_json_write_with_backup(audit_state, data)
"
  ok_msg "Completed boundary: $pair"
}

cmd_report() {
  if [ ! -f "$AUDIT_STATE" ]; then
    die "No audit state found."
  fi

  local report_file="$STATE_DIR/audit-report.md"

  CP_AUDIT_STATE="$AUDIT_STATE" python3 -c "
import json, os

with open(os.environ['CP_AUDIT_STATE']) as f:
    state = json.load(f)

domains = state['domains']
boundaries = state.get('boundaries', {})

lines = ['# Codebase Audit Report', '']
lines.append(f'**Target:** {state[\"target\"]}')
lines.append(f'**Domains:** {len(domains)}')
lines.append(f'**Total resolved:** {state[\"total_resolved\"]}')
lines.append(f'**Total deferred:** {state[\"total_deferred\"]}')
lines.append('')

lines.append('## Domain Summary')
lines.append('')
lines.append('| Domain | Tier | Status | Issues | Resolved | Deferred |')
lines.append('|--------|------|--------|--------|----------|----------|')

tier_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
for name, d in sorted(domains.items(), key=lambda x: (tier_order.get(x[1].get('tier','low'), 99), x[0])):
    lines.append(f'| {name} | {d.get(\"tier\",\"?\")} | {d[\"status\"]} | {d[\"issues_found\"]} | {d[\"issues_resolved\"]} | {d[\"issues_deferred\"]} |')

lines.append('')

if boundaries:
    lines.append('## Cross-Domain Boundaries')
    lines.append('')
    lines.append('| Boundary | Status | Files |')
    lines.append('|----------|--------|-------|')
    for key, b in sorted(boundaries.items()):
        lines.append(f'| {key} | {b[\"status\"]} | {len(b.get(\"files\",[]))} |')
    lines.append('')

all_done = all(d['status'] == 'done' for d in domains.values())
all_boundaries_done = all(b['status'] == 'done' for b in boundaries.values()) if boundaries else True

if all_done and all_boundaries_done:
    lines.append('## Coverage: COMPLETE')
    lines.append('')
    lines.append('All domains and boundaries have been audited.')
else:
    lines.append('## Coverage: PARTIAL')
    lines.append('')
    pending = [n for n, d in domains.items() if d['status'] != 'done']
    if pending:
        lines.append(f'**Domains remaining:** {\", \".join(pending)}')
    pending_b = [k for k, b in boundaries.items() if b['status'] != 'done']
    if pending_b:
        lines.append(f'**Boundaries remaining:** {\", \".join(pending_b)}')

print('\n'.join(lines))
" > "$report_file"

  ok_msg "Report written to $report_file"
  cat "$report_file"
}

cmd_merge_findings() {
  ensure_state_dir
  local findings_dir="$STATE_DIR"
  local merged_file="$STATE_DIR/merged-findings.json"

  info_msg "Merging parallel agent findings..."

  CP_DIR="$findings_dir" CP_OUT="$merged_file" python3 -c "
${ATOMIC_WRITE_PY}
import json, os, glob

findings_dir = os.environ['CP_DIR']
output_file = os.environ['CP_OUT']

pattern = os.path.join(findings_dir, '*-findings.json')
finding_files = glob.glob(pattern)

if not finding_files:
    print('No findings files (*-findings.json) found in ' + findings_dir)
    import sys; sys.exit(1)

all_issues = []
seen = set()

for fpath in sorted(finding_files):
    try:
        with open(fpath) as f:
            data = json.load(f)
        for issue in data.get('issues', []):
            key = (issue.get('file',''), issue.get('line',0), issue.get('description',''))
            if key not in seen:
                seen.add(key)
                all_issues.append(issue)
    except Exception as e:
        print(f'WARN: Could not read {fpath}: {e}')

merged = {
    'version': 1,
    'source': 'merged',
    'source_files': [os.path.basename(f) for f in finding_files],
    'issues': all_issues
}

atomic_json_write_with_backup(output_file, merged)
print(f'Merged {len(all_issues)} unique issues from {len(finding_files)} files')
print(f'Written to {output_file}')
"
}

# --- Dispatch ---
case "${1:-help}" in
  init)              shift; cmd_init "$@" ;;
  status)            cmd_status ;;
  next-domain)       cmd_next_domain ;;
  start-domain)      shift; cmd_start_domain "$@" ;;
  complete-domain)   shift; cmd_complete_domain "$@" ;;
  find-boundaries)   shift; cmd_find_boundaries "$@" ;;
  start-boundary)    shift; cmd_start_boundary "$@" ;;
  complete-boundary) shift; cmd_complete_boundary "$@" ;;
  merge-findings)    cmd_merge_findings ;;
  report)            cmd_report ;;
  help|*)
    cat <<'USAGE'
Usage: scripts/audit-state.sh <command> [args...]

Commands:
  init [target]                 Initialize audit from triage.json
  status                        Show audit progress
  next-domain                   Get next domain to audit
  start-domain <name>           Mark domain as in-progress
  complete-domain <name>        Mark domain as done
  find-boundaries [target]      Discover cross-domain boundaries
  start-boundary <pair>         Start boundary audit
  complete-boundary <pair>      Complete boundary audit
  merge-findings                Merge parallel agent findings
  report                        Generate final audit report
USAGE
    ;;
esac
