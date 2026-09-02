#!/usr/bin/env bash
# Record one known, unfixed owned-skill defect in local state.
set -euo pipefail
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  echo "usage: report-problem.sh <summary> [observed] [tried]"
  exit 0
fi
[ $# -ge 1 ] && [ $# -le 3 ] || { echo "usage: report-problem.sh <summary> [observed] [tried]" >&2; exit 64; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
skill=$(basename "$(dirname "$here")")
state_root=${AGENT_SKILLS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-skills}
dir=$state_root/$skill; file=$dir/PROBLEMS.md; lock=$dir/.problems-lock
mkdir -p "$dir"
n=0; until mkdir "$lock" 2>/dev/null; do n=$((n + 1)); [ "$n" -lt 50 ] || { echo "problem log is locked: $file" >&2; exit 75; }; sleep 0.1; done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
[ -f "$file" ] || printf '# Problems\n' > "$file"
observed=${2:-$1}; tried=${3:-none}
if grep -Fq "Problem: $observed" "$file"; then printf '%s\n' "$file"; exit 0; fi
{
  printf '\n## %s %s\n\n' "$(date +%F)" "$1"
  printf 'Problem: %s\n' "$observed"
  printf 'Tried: %s\n' "$tried"
  printf 'Status: open\n'
} >> "$file"
printf '%s\n' "$file"
