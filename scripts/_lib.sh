#!/usr/bin/env bash
# Shared library for Code Perfection scripts.
# Source this file — do not execute directly.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# --- Color constants ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Shared paths ---
STATE_DIR=".codeperfect"
AUDIT_STATE="$STATE_DIR/audit-state.json"
TRIAGE_FILE="$STATE_DIR/triage.json"
ISSUES_FILE="$STATE_DIR/issues.json"
LOCK_FILE="$STATE_DIR/fix.lock"
ITERATION_FILE="$STATE_DIR/iteration-count"

# --- Python atomic write helper (embedded in python3 -c calls) ---
# Writes JSON to a temp file, fsyncs, then atomic-renames.
# Handles disk-full by catching OSError and cleaning up.
ATOMIC_WRITE_PY='
import tempfile
def atomic_json_write(filepath, data):
    import json, os
    dir_ = os.path.dirname(os.path.abspath(filepath))
    fd, tmp = tempfile.mkstemp(dir=dir_, suffix=".tmp", prefix=".cpstate_")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, filepath)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise

def safe_json_load(filepath):
    """Load JSON with corruption recovery. Returns (data, was_corrupted)."""
    import json, os, shutil
    try:
        with open(filepath) as f:
            return json.load(f), False
    except json.JSONDecodeError:
        # Try backup
        backup = filepath + ".bak"
        if os.path.exists(backup):
            try:
                with open(backup) as f:
                    data = json.load(f)
                # Restore from backup
                shutil.copy2(backup, filepath)
                import sys
                print(f"WARN: Recovered {filepath} from backup (was corrupted)", file=sys.stderr)
                return data, True
            except Exception:
                pass
        raise

def atomic_json_write_with_backup(filepath, data):
    """Write JSON atomically and keep a .bak copy for corruption recovery."""
    import os, shutil
    if os.path.exists(filepath):
        shutil.copy2(filepath, filepath + ".bak")
    atomic_json_write(filepath, data)
'

# --- Bash helpers ---

ensure_state_dir() {
  mkdir -p "$STATE_DIR" "$STATE_DIR/domains"
}

# die <message> — print error and exit 1
die() {
  printf "${RED}ERROR${NC}: %s\n" "$1" >&2
  exit 1
}

# warn_msg <message> — print warning
warn_msg() {
  printf "${YELLOW}WARN${NC}: %s\n" "$1"
}

# info_msg <message> — print info
info_msg() {
  printf "${CYAN}INFO${NC}: %s\n" "$1"
}

# ok_msg <message> — print success
ok_msg() {
  printf "${GREEN}OK${NC}: %s\n" "$1"
}

# check_python3 — fail fast if python3 is missing
check_python3() {
  command -v python3 &>/dev/null || die "python3 is required but not found in PATH"
}

# check_git — fail fast if git is missing
check_git() {
  command -v git &>/dev/null || die "git is required but not found in PATH"
}

# utc_timestamp — emit UTC ISO 8601 timestamp
utc_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# --- Pure-bash JSON hot-path helpers ---
# These avoid spawning python3 for simple reads.
# They use basic text parsing — valid only for well-formatted JSON from our own scripts.

# json_count_array <file> <array_key>
# Counts elements in a top-level JSON array by counting "id" fields (for issues).
json_count_issues() {
  local file="$1"
  local count=0
  while IFS= read -r line; do
    if [[ "$line" == *'"id":'* ]]; then
      count=$((count + 1))
    fi
  done < "$file"
  echo "$count"
}

# json_max_issue_id <file>
# Returns the next ISS-N id by scanning for the highest existing numeric id.
json_next_issue_id() {
  local file="$1"
  local max_num=0
  local num
  while IFS= read -r line; do
    if [[ "$line" == *'"id": "ISS-'* ]]; then
      num="${line#*ISS-}"
      num="${num%%\"*}"
      if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt "$max_num" ]; then
        max_num="$num"
      fi
    fi
  done < "$file"
  echo "ISS-$((max_num + 1))"
}

# json_has_status <file> <status>
# Returns 0 if any issue has the given status, 1 otherwise. Pure bash.
json_has_status() {
  local file="$1"
  local status="$2"
  while IFS= read -r line; do
    if [[ "$line" == *"\"status\": \"${status}\""* ]]; then
      return 0
    fi
  done < "$file"
  return 1
}

# json_count_by_status <file> <status>
# Counts issues with the given status. Pure bash.
json_count_by_status() {
  local file="$1"
  local status="$2"
  local count=0
  while IFS= read -r line; do
    if [[ "$line" == *"\"status\": \"${status}\""* ]]; then
      count=$((count + 1))
    fi
  done < "$file"
  echo "$count"
}
