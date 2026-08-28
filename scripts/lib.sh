#!/usr/bin/env bash
# Shared helpers for claude-issue-agent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/global-config.sh"

AGENT_HOME="$CLAUDE_ISSUE_AGENT_HOME"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

slug() { echo "${1/\//__}"; }
inst_dir() { echo "$AGENT_HOME/$(slug "$1")"; }

load_config() {
  local repo="$1"
  local cfg="$(inst_dir "$repo")/config.env"
  [ -f "$cfg" ] || die "No config for $repo. Run setup.sh first."
  # shellcheck disable=SC1090
  . "$cfg"
}

# Model short names usable as labels. A label is a model label when it is one of
# these, optionally followed by an effort suffix: sonnet-5-low, fable-5-high.
KNOWN_MODELS="$CLAUDE_ISSUE_KNOWN_MODELS"
VALID_EFFORTS="$CLAUDE_ISSUE_VALID_EFFORTS"

# "sonnet-5-low"  -> "claude-sonnet-5|low"
# "opus-4-6"      -> "claude-opus-4-6|high"    (the -6 belongs to the name)
# Returns 1 when the string is not a model label at all.
parse_model_label() {
  local spec="$1" base effort="${DEFAULT_EFFORT:-high}" e m
  base="$spec"
  for e in $VALID_EFFORTS; do
    case "$spec" in
      *-"$e") base="${spec%-$e}"; effort="$e"; break ;;
    esac
  done
  for m in $KNOWN_MODELS; do
    if [ "$base" = "$m" ]; then
      echo "claude-$base|$effort"
      return 0
    fi
  done
  return 1
}

# Pick the model label out of an issue's labels. Prints "model|effort", or
# the configured default when the issue carries no model label.
model_from_labels() {
  local labels="$1" l pair
  for l in $labels; do
    if pair="$(parse_model_label "$l")"; then
      echo "$pair"; return 0
    fi
  done
  echo "${DEFAULT_MODEL:-$CLAUDE_ISSUE_DEFAULT_MODEL}|${DEFAULT_EFFORT:-$CLAUDE_ISSUE_DEFAULT_EFFORT}"
}

# Deterministic UUIDv4-shaped session id from a key string.
# The same issue always maps to the same Claude session, even if state is lost.
issue_uuid() {
  local key="$1" h=""
  # Order is a compatibility contract, not a preference: a different hasher means
  # a different id, which silently orphans an issue's conversation. md5 first
  # (macOS), then md5sum (Linux) — matching what installs before this comment
  # existed already computed — with shasum only as a last resort. The PATH the
  # service managers export now includes /sbin, where macOS keeps md5.
  # A hard failure beats a malformed id that Claude rejects several layers later.
  if command -v md5 >/dev/null 2>&1; then
    h=$(printf '%s' "$key" | md5 -q 2>/dev/null || true)
  elif command -v md5sum >/dev/null 2>&1; then
    h=$(printf '%s' "$key" | md5sum 2>/dev/null | cut -d' ' -f1 || true)
  elif command -v shasum >/dev/null 2>&1; then
    h=$(printf '%s' "$key" | shasum 2>/dev/null | cut -c1-32 || true)
  fi
  case "$h" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) die "cannot hash a session id for '$key' (need md5, md5sum or shasum on PATH; got: '$h')" ;;
  esac
  printf '%s-%s-4%s-a%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# Has Claude ever written this session to disk? The projects/ directory name is
# a mangled form of the cwd (dots and underscores become hyphens too), so glob
# for the file instead of trying to reproduce the encoding.
session_exists() {
  ls "$CLAUDE_PROJECTS_DIR"/*/"$1.jsonl" >/dev/null 2>&1
}

state_file() { echo "$(inst_dir "$1")/state/issue-$2.json"; }

read_state() {
  local f; f="$(state_file "$1" "$2")"
  if [ -f "$f" ]; then cat "$f"; else echo '{}'; fi
}

# Write through a temp file and rename: a reader must never see the truncated
# window a plain redirect opens, and two writers must not interleave.
write_state() {
  local f tmp
  f="$(state_file "$1" "$2")"
  mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"
  cat > "$tmp" && mv -f "$tmp" "$f"
}

# Hidden marker: must stay on the first line. poll.sh uses it to skip the
# agent's own comments, otherwise it would reply to itself forever.
AGENT_MARKER='<!-- claude-issue-agent -->'

# Comments the agent must not act on: its own, and human notes starting with //.
# A note never becomes a prompt and never interrupts a running turn, so you can
# think out loud on an issue without waking anything up.
jq_ignore() {
  printf '. as $c | select(($c.body | startswith("%s")) | not)
          | select(($c.body | sub("^[[:space:]]+"; "") | startswith("//")) | not)
          | select(($allow == "") or (($allow | split(" ")) | index($c.login) != null))' \
    "$AGENT_MARKER"
}

# Visible banner so a reader can tell at a glance who wrote a comment. Only the
# framing is English — Claude answers in whatever language the issue uses.
AGENT_HEADER='**Claude Code:**'
