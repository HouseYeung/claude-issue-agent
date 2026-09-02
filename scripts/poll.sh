#!/usr/bin/env bash
# Watch one repository for issues carrying this machine's label. Dispatch each
# one to run-task.sh in the background, and kill a running turn the moment a new
# comment arrives. Runs forever; stop it with ctl.sh stop.
# Usage: poll.sh <owner/repo>
set -euo pipefail
# Answered first: --help must not read configuration or reach GitHub.
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  printf '%s\n' "usage: poll.sh <owner/repo>"
  exit 0
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

REPO="${1:?usage: poll.sh <owner/repo>}"
load_config "$REPO"
DIR="$(inst_dir "$REPO")"
mkdir -p "$DIR/logs" "$DIR/state"

[ -n "${AGENT_LABEL:-}" ] || die "AGENT_LABEL is empty in config.env. Nothing can route here."

LOCK="$DIR/poll.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A kill -9 leaves the lock behind with a dead owner. Refusing to start on
  # that would defeat restart-on-crash entirely: every relaunch the service
  # manager attempts hits the stale lock and dies. Only a live owner wins.
  lpid="$(cat "$LOCK/pid" 2>/dev/null || echo '')"
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
    die "Already running (pid $lpid, lock: $LOCK). Use ctl.sh stop $REPO to clear it."
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || die "Cannot claim lock: $LOCK"
fi
echo $$ > "$LOCK/pid"
# Bash runs a signal trap and then carries on, so trapping TERM on the cleanup
# alone would drop the lock and keep looping — a stop that does not stop.
# Exit explicitly, and as a success: a signalled stop is the intended way out,
# not a crash the service manager should report as failed.
cleanup() { rm -rf "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# Report the trust boundary at startup: it is the one setting whose default
# ("anyone") is only safe because the repo is private.
if [ -n "${ALLOWED_USERS:-}" ]; then
  log "only these users can trigger runs: $ALLOWED_USERS"
fi

SKIP_LOGGED=""

# The single most common silent failure: the label the watcher filters on does
# not exist in the repository, so gh returns an empty list forever and the
# watcher looks perfectly healthy. Renaming conventions between versions cause
# exactly this. Warn rather than exit: a transient API error should not stop a
# watcher that is otherwise fine.
if gh label list --repo "$REPO" --limit 200 --json name --jq '.[].name' 2>/dev/null \
   | grep -qx "$AGENT_LABEL"; then
  :
else
  log "WARNING: label '$AGENT_LABEL' does not exist in $REPO (or it could not be listed)."
  log "         Nothing routes here until an issue carries it. Create it with:"
  log "         gh label create '$AGENT_LABEL' --repo $REPO --color 7C3AED"
fi

log "watching $REPO  label=$AGENT_LABEL  model=$DEFAULT_MODEL/$DEFAULT_EFFORT  perms=$PERMISSION_MODE"

# ---------------------------------------------------------------- helpers
# Newest comment that is NOT ours. The agent posts a placeholder while it works,
# and counting that as a new comment would make every run interrupt itself.
# Newest comment this machine is allowed to act on. Slurping through a second
# jq matters: --paginate runs the --jq filter once per page, so a repo with more
# than one page of comments would print one id per page and every numeric test
# downstream would break.
# Fails rather than answering 0. A transient API error used to read as "no
# comments", the watermark was then written as 0, and the next pass replayed the
# entire comment history as a fresh prompt.
newest_comment_id() {
  local raw
  raw="$(gh api "repos/$REPO/issues/$1/comments" --paginate --jq '.[]' 2>/dev/null)" || return 1
  printf '%s' "$raw" \
    | jq -s --arg allow "${ALLOWED_USERS:-}" "[.[] | $(jq_ignore)] | (.[-1].id) // 0" 2>/dev/null \
    || return 1
}

running_pid() {
  local f="$DIR/state/issue-$1.runpid"
  [ -f "$f" ] || return 1
  local pid; pid="$(cat "$f")"
  kill -0 "$pid" 2>/dev/null || { rm -f "$f"; return 1; }
  echo "$pid"
}

# Kill only the claude process. run-task.sh is waiting on it and needs to stay
# alive long enough to record the interrupted state and exit cleanly; killing
# the wrapper too would lose that, and the next pass would restart the issue
# from its body instead of continuing the conversation.
interrupt_run() {
  local num="$1" cpid rpid i=0
  cpid="$DIR/state/issue-$num.claudepid"
  # Marks this exit as deliberate. Without it run-task.sh cannot tell a stop it
  # asked for from an OOM kill, and would file a crash as a clean interruption.
  touch "$DIR/state/issue-$num.interrupt"
  # Negative pid signals the whole process group, so tools Claude spawned die
  # with it instead of surviving to fight the next run over the same worktree.
  [ -f "$cpid" ] && { kill -TERM "-$(cat "$cpid")" 2>/dev/null || kill -TERM "$(cat "$cpid")" 2>/dev/null; } || true

  while running_pid "$num" >/dev/null && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done

  if rpid="$(running_pid "$num")"; then
    log "issue #$num: run-task did not exit in ${i}s, forcing it"
    [ -f "$cpid" ] && { kill -9 "-$(cat "$cpid")" 2>/dev/null || kill -9 "$(cat "$cpid")" 2>/dev/null; }
    kill -9 "$rpid" 2>/dev/null || true
    rm -f "$DIR/state/issue-$num.runpid" "$cpid"
  fi
  log "issue #$num: interrupted by a new comment"
}

# ---------------------------------------------------------------- one issue
# Empty allowlist means anyone who can label an issue here. That is the default
# because setup.sh refuses public repos, so "anyone" is already "a collaborator".
user_allowed() {
  [ -z "${ALLOWED_USERS:-}" ] && return 0
  local u
  for u in $ALLOWED_USERS; do
    [ "$u" = "$1" ] && return 0
  done
  return 1
}

handle_issue() {
  local num="$1" title="$2" body="$3" labels="$4" author="$5"
  local state started last_id newest prompt

  if ! user_allowed "$author"; then
    case " $SKIP_LOGGED " in
      *" $num "*) : ;;
      *) log "issue #$num: author $author is not in ALLOWED_USERS, ignoring"
         SKIP_LOGGED="$SKIP_LOGGED $num" ;;
    esac
    return 0
  fi

  state="$(read_state "$REPO" "$num")"
  started="$(echo "$state" | jq -r '.started // false')"
  last_id="$(echo "$state" | jq -r '.last_comment_id // 0')"
  if ! newest="$(newest_comment_id "$num")"; then
    log "issue #$num: comments unreadable this pass, leaving the watermark alone"
    return 0
  fi
  case "$newest" in ''|*[!0-9]*) log "issue #$num: unusable comment watermark, skipping this pass"; return 0 ;; esac

  # A turn is in flight. A newer comment than the one it started from means the
  # human is talking over it, so cut it off now and let the next pass restart.
  if running_pid "$num" >/dev/null; then
    if [ "$newest" -gt "$last_id" ]; then interrupt_run "$num"; fi
    return 0
  fi

  [ "$(echo "$state" | jq -r '.fails // 0')" -ge 3 ] && return 0

  prompt="$(mktemp)"

  if [ "$started" != "true" ]; then
    local pair model effort
    pair="$(model_from_labels "$labels")"
    model="${pair%|*}"; effort="${pair#*|}"
    state="$(echo "$state" | jq --arg m "$model" --arg e "$effort" '.model = $m | .effort = $e')"
    # Comments made before the first pickup are part of the request. Dropping
    # them, then advancing the watermark past them, lost them permanently.
    local pre
    if ! pre="$(gh api "repos/$REPO/issues/$num/comments" --paginate --jq '.[]' 2>/dev/null \
           | jq -rs --arg allow "${ALLOWED_USERS:-}" \
             "[.[] | $(jq_ignore) | \"@\(\$c.login):\n\(\$c.body)\"] | join(\"\n\n---\n\n\")" \
           2>/dev/null)"; then
      log "issue #$num: earlier comments unreadable, deferring the first turn"
      rm -f "$prompt"; return 0
    fi
    { echo "# $title"; echo; echo "$body"
      [ -n "$pre" ] && { echo; echo "---"; echo; echo "$pre"; }
    } > "$prompt"
    log "issue #$num: new task  model=$model effort=$effort"
  else
    local comments fresh
    comments="$(gh api "repos/$REPO/issues/$num/comments" --paginate \
      --jq '[.[] | {id: .id, login: .user.login, body: .body}]' 2>/dev/null || echo '[]')"
    fresh="$(echo "$comments" | jq -r --argjson last "$last_id" --arg allow "${ALLOWED_USERS:-}" \
      "[.[] | select(.id > \$last) | $(jq_ignore)
            | \"@\(\$c.login):\n\(\$c.body)\"] | join(\"\n\n---\n\n\")")"
    if [ -z "$fresh" ]; then rm -f "$prompt"; return 0; fi
    echo "$fresh" > "$prompt"
    log "issue #$num: follow-up"
  fi

  # Record the watermark before launching, so anything posted from here on
  # counts as an interruption.
  echo "$state" | jq --argjson n "$newest" '.last_comment_id = $n' \
    | write_state "$REPO" "$num"

  # Background: the main loop keeps polling and can kill this run.
  ( # `rc=$?` on the next line would never run under the inherited set -e: the
    # subshell exits at the failing command, skipping the whole failure path,
    # so .fails never grows and a hard error retries forever.
    if "$HERE/run-task.sh" "$REPO" "$num" "$prompt" >> "$DIR/logs/issue-$num.log" 2>&1; then
      rc=0
    else
      rc=$?
    fi
    if [ $rc -eq 75 ]; then
      # Usage limit. The task is fine; the account is out of room for now.
      log "issue #$num: waiting on the usage window to reset"
    elif [ $rc -ne 0 ]; then
      log "issue #$num: run-task failed (rc=$rc) -> $DIR/logs/issue-$num.log"
      f="$(read_state "$REPO" "$num" | jq -r '.fails // 0')"
      read_state "$REPO" "$num" | jq --argjson f "$((f + 1))" '.fails = $f' \
        | write_state "$REPO" "$num"
    else
      read_state "$REPO" "$num" | jq '.fails = 0' | write_state "$REPO" "$num"
    fi
    # No watermark bump here. The agent's own comments are filtered out by
    # marker anyway, and pushing the mark to "now" would consume a human comment
    # posted between the last poll and the end of the run — it would never
    # reach a prompt.
    rm -f "$prompt"
  ) >> "$DIR/logs/poll.log" 2>&1 &
}

# ---------------------------------------------------------------- main loop
while true; do
  issues="$(gh issue list --repo "$REPO" --label "$AGENT_LABEL" --state open \
    --limit 30 --json number,title,body,labels,author 2>/dev/null || echo '[]')"

  n="$(echo "$issues" | jq 'length')"
  nums=""
  for i in $(seq 0 $((n - 1))); do
    [ "$n" -eq 0 ] && break
    row="$(echo "$issues" | jq ".[$i]")"
    num="$(echo "$row" | jq -r .number)"
    nums="$nums $num"
    handle_issue "$num" \
      "$(echo "$row" | jq -r .title)" \
      "$(echo "$row" | jq -r .body)" \
      "$(echo "$row" | jq -r '[.labels[].name] | join(" ")')" \
      "$(echo "$row" | jq -r '.author.login')" \
      || log "handle_issue #$num failed"
  done

  # Measure after dispatching: a run launched this pass counts as in flight,
  # otherwise the loop would sleep the slow interval and miss an interruption.
  busy=0
  for num in $nums; do
    if running_pid "$num" >/dev/null; then busy=1; break; fi
  done
  if [ "$busy" -eq 1 ]; then sleep "$BUSY_INTERVAL"; else sleep "$POLL_INTERVAL"; fi
done
