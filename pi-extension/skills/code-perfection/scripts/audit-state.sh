#!/usr/bin/env bash
# Audit state manager — tracks domain-scoped audit progress.
# Prevents re-scanning done domains, enforces one-domain-at-a-time, manages resume.
# Usage: scripts/audit-state.sh <command> [args...]
set -euo pipefail

# Dependency check
if ! command -v python3 &>/dev/null; then
  printf "ERROR: python3 is required but not found in PATH.\n" >&2
  exit 1
fi

STATE_DIR=".codeperfect"
AUDIT_STATE="$STATE_DIR/audit-state.json"
TRIAGE_FILE="$STATE_DIR/triage.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ensure_state_dir() {
  mkdir -p "$STATE_DIR" "$STATE_DIR/domains"
}

cmd_init() {
  local target="${1:-.}"
  ensure_state_dir

  if [ ! -f "$TRIAGE_FILE" ]; then
    printf "${RED}ERROR${NC}: Run scripts/triage.sh first to generate %s\n" "$TRIAGE_FILE"
    exit 1
  fi

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  CP_TRIAGE="$TRIAGE_FILE" CP_TARGET="$target" CP_AUDIT_STATE="$AUDIT_STATE" \
  CP_TIMESTAMP="$timestamp" \
  python3 -c "
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

out = os.environ['CP_AUDIT_STATE']
tmp = out + '.tmp'
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, out)
print(f'Initialized audit state: {len(state[\"domains\"])} domains')
"
  printf "${GREEN}Audit state${NC} initialized at %s\n" "$AUDIT_STATE"
}

cmd_status() {
  if [ ! -f "$AUDIT_STATE" ]; then
    printf "${RED}ERROR${NC}: No audit state found. Run: scripts/audit-state.sh init <target>\n"
    exit 1
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
    printf "${RED}ERROR${NC}: No audit state found.\n"
    exit 1
  fi

  CP_AUDIT_STATE="$AUDIT_STATE" python3 -c "
import json, os, sys
with open(os.environ['CP_AUDIT_STATE']) as f:
    state = json.load(f)

# Check for in-progress domain first
for name, d in state['domains'].items():
    if d['status'] == 'in_progress':
        print(f'RESUME: {name} (already in progress)')
        sys.exit(0)

# Find next pending domain by tier priority
tier_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
pending = [(name, d) for name, d in state['domains'].items() if d['status'] == 'pending']
pending.sort(key=lambda x: (tier_order.get(x[1].get('tier','low'), 99), x[0]))

if pending:
    print(f'NEXT: {pending[0][0]} (tier: {pending[0][1].get(\"tier\",\"unknown\")})')
    sys.exit(0)
else:
    print('ALL_DOMAINS_DONE')
    sys.exit(0)
"
}

cmd_start_domain() {
  if [ $# -lt 1 ]; then
    printf "${RED}ERROR${NC}: start-domain requires 1 argument: <name>\n" >&2
    exit 1
  fi
  local name="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  CP_AUDIT_STATE="$AUDIT_STATE" CP_NAME="$name" CP_TIMESTAMP="$timestamp" \
  python3 -c "
import json, os, sys
audit_state = os.environ['CP_AUDIT_STATE']
domain_name = os.environ['CP_NAME']
timestamp = os.environ['CP_TIMESTAMP']
with open(audit_state) as f:
    state = json.load(f)

# Check no other domain is in_progress
for dname, d in state['domains'].items():
    if d['status'] == 'in_progress' and dname != domain_name:
        print(f'ERROR: Domain {dname} is already in_progress. Complete it first.')
        sys.exit(1)

if domain_name not in state['domains']:
    print(f'ERROR: Domain {domain_name} not found in audit state')
    sys.exit(1)

if state['domains'][domain_name]['status'] == 'done':
    print(f'ERROR: Domain {domain_name} is already done. Use --force to re-audit.')
    sys.exit(1)

state['domains'][domain_name]['status'] = 'in_progress'
state['last_updated'] = timestamp
tmp = audit_state + '.tmp'
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, audit_state)
print(f'Started domain: {domain_name}')
"
  printf "${CYAN}Started${NC} domain: %s\n" "$name"

  # Initialize resolution loop for this domain
  mkdir -p "$STATE_DIR/domains/$name"
}

cmd_complete_domain() {
  if [ $# -lt 1 ]; then
    printf "${RED}ERROR${NC}: complete-domain requires 1 argument: <name>\n" >&2
    exit 1
  fi
  local name="$1"

  # Read resolution loop results if they exist
  local issues_found=0
  local issues_resolved=0
  local issues_deferred=0

  if [ -f "$STATE_DIR/issues.json" ]; then
    read -r issues_found issues_resolved issues_deferred < <(CP_ISSUES="$STATE_DIR/issues.json" python3 -c "
import json, os
with open(os.environ['CP_ISSUES']) as f:
    data = json.load(f)
issues = data['issues']
total = len(issues)
done = sum(1 for i in issues if i['status'] == 'done')
deferred = sum(1 for i in issues if i['status'] == 'deferred')
print(f'{total} {done} {deferred}')
" 2>/dev/null || echo "0 0 0")

    # Archive domain issues
    cp "$STATE_DIR/issues.json" "$STATE_DIR/domains/$name/issues.json" 2>/dev/null || true
  fi

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  CP_AUDIT_STATE="$AUDIT_STATE" CP_NAME="$name" CP_TIMESTAMP="$timestamp" \
  CP_FOUND="$issues_found" CP_RESOLVED="$issues_resolved" CP_DEFERRED="$issues_deferred" \
  python3 -c "
import json, os, sys
audit_state = os.environ['CP_AUDIT_STATE']
domain_name = os.environ['CP_NAME']
with open(audit_state) as f:
    state = json.load(f)

if domain_name not in state['domains']:
    print(f'ERROR: Domain {domain_name} not found in audit state')
    sys.exit(1)
if state['domains'][domain_name]['status'] != 'in_progress':
    print(f'ERROR: Domain {domain_name} has status \"{state[\"domains\"][domain_name][\"status\"]}\" — must be in_progress to complete')
    sys.exit(1)

state['domains'][domain_name]['status'] = 'done'
state['domains'][domain_name]['issues_found'] = int(os.environ['CP_FOUND'])
state['domains'][domain_name]['issues_resolved'] = int(os.environ['CP_RESOLVED'])
state['domains'][domain_name]['issues_deferred'] = int(os.environ['CP_DEFERRED'])
state['total_resolved'] = sum(d['issues_resolved'] for d in state['domains'].values())
state['total_deferred'] = sum(d['issues_deferred'] for d in state['domains'].values())
state['last_updated'] = os.environ['CP_TIMESTAMP']
tmp = audit_state + '.tmp'
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, audit_state)
"
  printf "${GREEN}Completed${NC} domain: %s (found=%d resolved=%d deferred=%d)\n" \
    "$name" "$issues_found" "$issues_resolved" "$issues_deferred"
}

cmd_find_boundaries() {
  local target="${1:-.}"

  if [ ! -f "$AUDIT_STATE" ]; then
    printf "${RED}ERROR${NC}: No audit state found.\n"
    exit 1
  fi

  printf "${CYAN}Discovering${NC} cross-domain boundaries in %s...\n" "$target"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  CP_AUDIT_STATE="$AUDIT_STATE" CP_TARGET="$target" CP_TIMESTAMP="$timestamp" \
  python3 -c "
import json, os, re

audit_state = os.environ['CP_AUDIT_STATE']
target = os.environ['CP_TARGET']
timestamp = os.environ['CP_TIMESTAMP']

with open(audit_state) as f:
    state = json.load(f)

domain_names = list(state['domains'].keys())
boundaries = {}

# Pre-compile regex patterns for each domain to avoid recompilation per file
SOURCE_EXTS = frozenset(('.ts', '.tsx', '.js', '.jsx', '.py', '.go', '.rs'))
SKIP_DIRS = frozenset(('node_modules', 'dist', 'build', '.git', '__pycache__', '.venv', '.codeperfect'))
domain_patterns = {}
for d in domain_names:
    escaped = re.escape(d)
    domain_patterns[d] = re.compile(
        rf'(?:from\s+[\"\\x27]|import\s+.*[\"\\x27]|require\([\"\\x27]).*{escaped}'
    )

# Pre-compute domain path prefixes for fast lookup
domain_prefixes = [(d, os.path.join(target, d) + os.sep) for d in domain_names]

# Scan for cross-domain imports
for root, dirs, files in os.walk(target):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
    for fname in files:
        ext = os.path.splitext(fname)[1]
        if ext not in SOURCE_EXTS:
            continue
        fpath = os.path.join(root, fname)
        try:
            with open(fpath, 'r', errors='ignore') as f:
                content = f.read()
        except Exception:
            continue

        # Find which domain this file belongs to using prefix match
        file_domain = None
        for d, prefix in domain_prefixes:
            if fpath.startswith(prefix):
                file_domain = d
                break
        if not file_domain:
            continue

        # Find imports that reference other domains using pre-compiled patterns
        for other in domain_names:
            if other == file_domain:
                continue
            if domain_patterns[other].search(content):
                key = '-'.join(sorted([file_domain, other]))
                if key not in boundaries:
                    boundaries[key] = {'status': 'pending', 'files': []}
                if fpath not in boundaries[key]['files']:
                    boundaries[key]['files'].append(fpath)

state['boundaries'] = boundaries
state['last_updated'] = timestamp
tmp = audit_state + '.tmp'
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, audit_state)

print(f'Found {len(boundaries)} boundary pairs:')
for key, b in sorted(boundaries.items()):
    print(f'  {key}: {len(b[\"files\"])} boundary files')
" 2>/dev/null || printf "${YELLOW}WARN${NC}: Boundary detection requires Python3\n"
}

cmd_start_boundary() {
  if [ $# -lt 1 ]; then
    printf "${RED}ERROR${NC}: start-boundary requires 1 argument: <pair>\n" >&2
    exit 1
  fi
  local pair="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  CP_AUDIT_STATE="$AUDIT_STATE" CP_PAIR="$pair" CP_TIMESTAMP="$timestamp" \
  python3 -c "
import json, os, sys
audit_state = os.environ['CP_AUDIT_STATE']
pair = os.environ['CP_PAIR']
with open(audit_state) as f:
    state = json.load(f)
if pair not in state.get('boundaries', {}):
    print(f'ERROR: Boundary {pair} not found')
    sys.exit(1)
state['boundaries'][pair]['status'] = 'in_progress'
state['last_updated'] = os.environ['CP_TIMESTAMP']
tmp = audit_state + '.tmp'
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, audit_state)
"
  printf "${CYAN}Started${NC} boundary audit: %s\n" "$pair"
}

cmd_complete_boundary() {
  if [ $# -lt 1 ]; then
    printf "${RED}ERROR${NC}: complete-boundary requires 1 argument: <pair>\n" >&2
    exit 1
  fi
  local pair="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  CP_AUDIT_STATE="$AUDIT_STATE" CP_PAIR="$pair" CP_TIMESTAMP="$timestamp" \
  python3 -c "
import json, os
audit_state = os.environ['CP_AUDIT_STATE']
pair = os.environ['CP_PAIR']
with open(audit_state) as f:
    state = json.load(f)
state['boundaries'][pair]['status'] = 'done'
state['last_updated'] = os.environ['CP_TIMESTAMP']
tmp = audit_state + '.tmp'
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
os.replace(tmp, audit_state)
"
  printf "${GREEN}Completed${NC} boundary: %s\n" "$pair"
}

cmd_report() {
  if [ ! -f "$AUDIT_STATE" ]; then
    printf "${RED}ERROR${NC}: No audit state found.\n"
    exit 1
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

# Coverage assessment
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

  printf "${GREEN}Report${NC} written to %s\n" "$report_file"
  cat "$report_file"
}

cmd_merge_findings() {
  ensure_state_dir
  local findings_dir="$STATE_DIR"
  local merged_file="$STATE_DIR/merged-findings.json"

  printf "${CYAN}Merging${NC} parallel agent findings...\n"

  CP_DIR="$findings_dir" CP_OUT="$merged_file" python3 -c "
import json, os, glob

findings_dir = os.environ['CP_DIR']
output_file = os.environ['CP_OUT']

# Find all *-findings.json files
pattern = os.path.join(findings_dir, '*-findings.json')
finding_files = glob.glob(pattern)

if not finding_files:
    print('No findings files (*-findings.json) found in ' + findings_dir)
    import sys; sys.exit(1)

all_issues = []
seen = set()  # deduplicate by (file, line, description)

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

tmp = output_file + '.tmp'
with open(tmp, 'w') as f:
    json.dump(merged, f, indent=2)
os.replace(tmp, output_file)

print(f'Merged {len(all_issues)} unique issues from {len(finding_files)} files')
print(f'Written to {output_file}')
"
}

# Dispatch
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
    printf "Usage: scripts/audit-state.sh <command> [args...]\n\n"
    printf "Commands:\n"
    printf "  init [target]                 Initialize audit from triage.json\n"
    printf "  status                        Show audit progress\n"
    printf "  next-domain                   Get next domain to audit\n"
    printf "  start-domain <name>           Mark domain as in-progress\n"
    printf "  complete-domain <name>        Mark domain as done\n"
    printf "  find-boundaries [target]      Discover cross-domain boundaries\n"
    printf "  start-boundary <pair>         Start boundary audit\n"
    printf "  complete-boundary <pair>      Complete boundary audit\n"
    printf "  merge-findings                Merge parallel agent findings\n"
    printf "  report                        Generate final audit report\n"
    ;;
esac
