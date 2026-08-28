#!/usr/bin/env bash
# Append a confirmed Skill defect to local state, never to the public repository.
set -euo pipefail
[ $# -ge 1 ] && [ $# -le 3 ] || { echo "usage: report-problem.sh <summary> [observed] [tried]" >&2; exit 64; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill="$(basename "$(dirname "$HERE")")"
state_root="${AGENT_SKILLS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-skills}"
dir="$state_root/$skill"; file="$dir/PROBLEMS.md"; lock="$dir/.problems-lock"
mkdir -p "$dir"
n=0; until mkdir "$lock" 2>/dev/null; do n=$((n + 1)); [ "$n" -lt 50 ] || { echo "problem log is locked: $file" >&2; exit 75; }; sleep 0.1; done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
[ -f "$file" ] || printf '# Problems\n' > "$file"
{
  printf '\n## %s %s\n\n' "$(date +%F)" "$1"
  printf 'Problem: %s\n' "${2:-$1}"
  printf 'Tried: %s\n' "${3:-none}"
  printf 'Status: open\n'
} >> "$file"
printf '%s\n' "$file"
