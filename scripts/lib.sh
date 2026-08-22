#!/usr/bin/env bash
# Shared helpers for claude-issue-agent.
set -euo pipefail

AGENT_HOME="${AGENT_HOME:-$HOME/.claude/claude-issue-agent}"

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
KNOWN_MODELS="fable-5 opus-5 opus-4-6 sonnet-5 haiku-4-5"
VALID_EFFORTS="low medium high xhigh max"

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
  echo "${DEFAULT_MODEL:-claude-opus-5}|${DEFAULT_EFFORT:-high}"
}

# Deterministic UUIDv4-shaped session id from a key string.
# The same issue always maps to the same Claude session, even if state is lost.
issue_uuid() {
  local key="$1" h
  if command -v md5 >/dev/null 2>&1; then
    h=$(printf '%s' "$key" | md5 -q)
  else
    h=$(printf '%s' "$key" | md5sum | cut -d' ' -f1)
  fi
  printf '%s-%s-4%s-a%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# Has Claude ever written this session to disk? The projects/ directory name is
# a mangled form of the cwd (dots and underscores become hyphens too), so glob
# for the file instead of trying to reproduce the encoding.
session_exists() {
  ls "$HOME/.claude/projects"/*/"$1.jsonl" >/dev/null 2>&1
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
