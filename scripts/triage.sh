#!/usr/bin/env bash
# Triage — structural recon without reading code.
# Discovers domains, classifies by risk tier, counts files, builds the audit roadmap.
# Usage: scripts/triage.sh <target-dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

check_python3

# Help
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  cat <<'USAGE'
Usage: scripts/triage.sh [target-dir]

Structural recon without reading code. Discovers domains, classifies
by risk tier, counts files, builds the audit roadmap.

Output: .codeperfect/triage.json
USAGE
  exit 0
fi

TARGET="${1:-.}"

if [ ! -d "$TARGET" ]; then
  die "Target directory does not exist: $TARGET"
fi

ensure_state_dir

info_msg "Triage: scanning $TARGET..."

CP_TARGET="$TARGET" CP_TRIAGE_FILE="$TRIAGE_FILE" python3 -c "
${ATOMIC_WRITE_PY}
import os, json, re, sys

target = os.environ['CP_TARGET']
triage_file = os.environ['CP_TRIAGE_FILE']

# Source file extensions
SOURCE_EXTS = frozenset({'.ts', '.tsx', '.js', '.jsx', '.py', '.go', '.rs', '.rb', '.java', '.kt', '.swift', '.c', '.cpp', '.h', '.hpp', '.cs', '.php', '.vue', '.svelte'})

# Directories to skip
SKIP_DIRS = frozenset({'node_modules', 'dist', 'build', '.git', '__pycache__', '.venv', 'vendor', '.next', 'coverage', '.codeperfect', '.tox', '.mypy_cache', '.pytest_cache', 'target', '.gradle'})

# Risk tier keywords
CRITICAL_KEYWORDS = frozenset({'auth', 'authentication', 'authorization', 'security', 'payment', 'payments', 'billing', 'checkout', 'gateway', 'middleware', 'crypto', 'token', 'session', 'oauth', 'jwt', 'password', 'credential'})
HIGH_KEYWORDS = frozenset({'api', 'service', 'controller', 'handler', 'route', 'routes', 'model', 'models', 'database', 'db', 'store', 'state', 'core', 'engine', 'processor', 'queue', 'worker', 'job'})
LOW_KEYWORDS = frozenset({'test', 'tests', 'spec', 'specs', '__tests__', 'fixtures', 'mocks', 'stubs', 'scripts', 'tools', 'docs', 'documentation', 'examples', 'demo', 'sample', 'migration', 'migrations', 'seed', 'seeds', 'config', 'configs'})

def classify_tier(dirname):
    lower = dirname.lower()
    if lower in CRITICAL_KEYWORDS or any(k in lower for k in CRITICAL_KEYWORDS):
        return 'critical'
    if lower in HIGH_KEYWORDS or any(k in lower for k in HIGH_KEYWORDS):
        return 'high'
    if lower in LOW_KEYWORDS or any(k in lower for k in LOW_KEYWORDS):
        return 'low'
    return 'medium'

# Discover domains (top-level directories)
domains = {}
total_files = 0
file_cap_per_domain = 500  # Scalability: cap stored file list

try:
    entries = sorted(os.listdir(target))
except PermissionError as e:
    print(f'ERROR: Cannot read target directory: {e}', file=sys.stderr)
    sys.exit(1)

for entry in entries:
    entry_path = os.path.join(target, entry)
    if not os.path.isdir(entry_path):
        continue
    if entry in SKIP_DIRS or entry.startswith('.'):
        continue
    # Sanitize domain name
    safe_name = re.sub(r'[^a-zA-Z0-9._-]', '_', entry)
    if safe_name != entry:
        print(f'  NOTE: Renamed domain \"{entry}\" -> \"{safe_name}\" (sanitized)')

    # Count source files using os.scandir for speed on large trees
    file_count = 0
    source_files = []
    stack = [entry_path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as it:
                for e in it:
                    if e.is_dir(follow_symlinks=False):
                        if e.name not in SKIP_DIRS and not e.name.startswith('.'):
                            stack.append(e.path)
                    elif e.is_file(follow_symlinks=False):
                        ext = os.path.splitext(e.name)[1]
                        if ext in SOURCE_EXTS:
                            file_count += 1
                            if len(source_files) < file_cap_per_domain:
                                source_files.append(e.path)
        except PermissionError:
            continue

    if file_count == 0:
        continue

    tier = classify_tier(entry)
    domains[safe_name] = {
        'name': safe_name,
        'path': entry_path,
        'tier': tier,
        'file_count': file_count,
        'files': source_files
    }
    total_files += file_count

# Root-level source files
root_files = []
try:
    with os.scandir(target) as it:
        for e in it:
            if e.is_file(follow_symlinks=False) and os.path.splitext(e.name)[1] in SOURCE_EXTS:
                root_files.append(e.path)
                total_files += 1
except PermissionError:
    pass

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

# Compute scan order (priority-ordered, capped for scalability)
scan_order = []
scan_cap = 2000
for d in sorted_domains:
    remaining = scan_cap - len(scan_order)
    if remaining <= 0:
        break
    scan_order.extend(d.get('files', [])[:remaining])

# Build triage output
triage = {
    'version': 1,
    'target': target,
    'total_files': total_files,
    'domain_count': len(domains),
    'domains': [{'name': d['name'], 'path': d['path'], 'tier': d['tier'], 'file_count': d['file_count']} for d in sorted_domains],
    'scan_order': scan_order,
    'tier_summary': {
        'critical': sum(1 for d in domains.values() if d['tier'] == 'critical'),
        'high': sum(1 for d in domains.values() if d['tier'] == 'high'),
        'medium': sum(1 for d in domains.values() if d['tier'] == 'medium'),
        'low': sum(1 for d in domains.values() if d['tier'] == 'low')
    }
}

atomic_json_write_with_backup(triage_file, triage)

# Print summary
print(f'Total source files: {total_files}')
print(f'Domains: {len(domains)}')
ts = triage['tier_summary']
print(f'  CRITICAL: {ts[\"critical\"]}  |  HIGH: {ts[\"high\"]}  |  MEDIUM: {ts[\"medium\"]}  |  LOW: {ts[\"low\"]}')
print()
for d in sorted_domains:
    print(f'  [{d[\"tier\"]:>8}] {d[\"name\"]:30s} {d[\"file_count\"]:>4} files')
"

ok_msg "Triage written to $TRIAGE_FILE"
