#!/usr/bin/env bash
# Triage — structural recon without reading code.
# Discovers domains, classifies by risk tier, counts files, builds the audit roadmap.
# Usage: scripts/triage.sh <target-dir>
set -euo pipefail

# Dependency check
if ! command -v python3 &>/dev/null; then
  printf "ERROR: python3 is required but not found in PATH.\n" >&2
  exit 1
fi

STATE_DIR=".codeperfect"
TRIAGE_FILE="$STATE_DIR/triage.json"
TARGET="${1:-.}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$STATE_DIR"

printf "${CYAN}Triage${NC}: scanning %s...\n" "$TARGET"

if [ ! -d "$TARGET" ]; then
  printf "${RED}ERROR${NC}: Target directory does not exist: %s\n" "$TARGET" >&2
  exit 1
fi

CP_TARGET="$TARGET" CP_TRIAGE_FILE="$TRIAGE_FILE" python3 -c "
import os, json, re, sys

target = os.environ['CP_TARGET']
triage_file = os.environ['CP_TRIAGE_FILE']

if not os.path.isdir(target):
    print(f'ERROR: Target directory does not exist: {target}', file=sys.stderr)
    sys.exit(1)

# Source file extensions
SOURCE_EXTS = {'.ts', '.tsx', '.js', '.jsx', '.py', '.go', '.rs', '.rb', '.java', '.kt', '.swift', '.c', '.cpp', '.h', '.hpp', '.cs', '.php', '.vue', '.svelte'}

# Directories to skip
SKIP_DIRS = {'node_modules', 'dist', 'build', '.git', '__pycache__', '.venv', 'vendor', '.next', 'coverage', '.codeperfect'}

# Risk tier keywords
CRITICAL_KEYWORDS = {'auth', 'authentication', 'authorization', 'security', 'payment', 'payments', 'billing', 'checkout', 'gateway', 'middleware', 'crypto', 'token', 'session', 'oauth', 'jwt', 'password', 'credential'}
HIGH_KEYWORDS = {'api', 'service', 'controller', 'handler', 'route', 'routes', 'model', 'models', 'database', 'db', 'store', 'state', 'core', 'engine', 'processor', 'queue', 'worker', 'job'}
LOW_KEYWORDS = {'test', 'tests', 'spec', 'specs', '__tests__', 'fixtures', 'mocks', 'stubs', 'scripts', 'tools', 'docs', 'documentation', 'examples', 'demo', 'sample', 'migration', 'migrations', 'seed', 'seeds', 'config', 'configs'}

def classify_tier(dirname):
    lower = dirname.lower()
    if lower in CRITICAL_KEYWORDS or any(k in lower for k in CRITICAL_KEYWORDS):
        return 'critical'
    if lower in HIGH_KEYWORDS or any(k in lower for k in HIGH_KEYWORDS):
        return 'high'
    if lower in LOW_KEYWORDS or any(k in lower for k in LOW_KEYWORDS):
        return 'low'
    return 'medium'

# Discover domains (top 2 levels)
domains = {}
total_files = 0

for entry in sorted(os.listdir(target)):
    entry_path = os.path.join(target, entry)
    if not os.path.isdir(entry_path):
        continue
    if entry in SKIP_DIRS or entry.startswith('.'):
        continue

    # Count source files in this domain
    file_count = 0
    source_files = []
    for root, dirs, files in os.walk(entry_path):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith('.')]
        for f in files:
            ext = os.path.splitext(f)[1]
            if ext in SOURCE_EXTS:
                file_count += 1
                source_files.append(os.path.join(root, f))

    if file_count == 0:
        continue

    tier = classify_tier(entry)
    domains[entry] = {
        'name': entry,
        'path': entry_path,
        'tier': tier,
        'file_count': file_count,
        'files': source_files[:200]  # cap for sanity
    }
    total_files += file_count

# Also check for source files directly in target (not in subdirectories)
root_files = []
for f in os.listdir(target):
    fpath = os.path.join(target, f)
    if os.path.isfile(fpath) and os.path.splitext(f)[1] in SOURCE_EXTS:
        root_files.append(fpath)
        total_files += 1

if root_files:
    domains['_root'] = {
        'name': '_root',
        'path': target,
        'tier': 'medium',
        'file_count': len(root_files),
        'files': root_files
    }

# Sort domains by tier priority
tier_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
sorted_domains = sorted(domains.values(), key=lambda d: (tier_order.get(d['tier'], 99), d['name']))

# Compute scan order (all files, priority-ordered)
scan_order = []
for d in sorted_domains:
    scan_order.extend(d.get('files', []))

# Build triage output
triage = {
    'version': 1,
    'target': target,
    'total_files': total_files,
    'domain_count': len(domains),
    'domains': [{'name': d['name'], 'path': d['path'], 'tier': d['tier'], 'file_count': d['file_count']} for d in sorted_domains],
    'scan_order': scan_order[:500],
    'tier_summary': {
        'critical': sum(1 for d in domains.values() if d['tier'] == 'critical'),
        'high': sum(1 for d in domains.values() if d['tier'] == 'high'),
        'medium': sum(1 for d in domains.values() if d['tier'] == 'medium'),
        'low': sum(1 for d in domains.values() if d['tier'] == 'low')
    }
}

with open(triage_file, 'w') as f:
    json.dump(triage, f, indent=2)

# Print summary
print(f'Total source files: {total_files}')
print(f'Domains: {len(domains)}')
ts = triage['tier_summary']
print(f'  CRITICAL: {ts[\"critical\"]}  |  HIGH: {ts[\"high\"]}  |  MEDIUM: {ts[\"medium\"]}  |  LOW: {ts[\"low\"]}')
print()
for d in sorted_domains:
    print(f'  [{d[\"tier\"]:>8}] {d[\"name\"]:30s} {d[\"file_count\"]:>4} files')
"

printf "\n${GREEN}Triage${NC} written to %s\n" "$TRIAGE_FILE"
