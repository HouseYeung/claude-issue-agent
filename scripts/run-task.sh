#!/usr/bin/env bash
# Run one Claude turn for one issue, then push the code and reply on GitHub.
# Usage: run-task.sh <owner/repo> <issue-number> <prompt-file>
set -euo pipefail
# Answered first: --help must not read configuration or reach GitHub.
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  printf '%s\n' "usage: run-task.sh <owner/repo> <issue-number> <prompt-file>"
  exit 0
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="${1:?repo}"; NUM="${2:?issue number}"; PROMPT_FILE="${3:?prompt file}"
load_config "$REPO"

DIR="$(inst_dir "$REPO")"
BRANCH="${BRANCH_PREFIX}${NUM}"
WT="$WORKTREE_ROOT/issue-$NUM"
SESSION_ID="$(issue_uuid "$REPO#$NUM")"
STATE="$(read_state "$REPO" "$NUM")"
STARTED="$(echo "$STATE" | jq -r '.started // false')"

# poll.sh pins these when the issue starts. They never change mid-issue.
MODEL="$(echo "$STATE" | jq -r --arg d "$DEFAULT_MODEL" '.model // $d')"
EFFORT="$(echo "$STATE" | jq -r --arg d "$DEFAULT_EFFORT" '.effort // $d')"

PIDFILE="$DIR/state/issue-$NUM.runpid"
CPIDFILE="$DIR/state/issue-$NUM.claudepid"
mkdir -p "$DIR/state"
echo $$ > "$PIDFILE"

HB_PID=""                                    # progress poster
PIDS_FILE="$DIR/state/issue-$NUM.progressids"  # node ids of the comments it posts

# Progress comments exist to notify while the turn runs. Once the real reply is
# in they are collapsed rather than deleted — the notification already went out,
# and folding them keeps the issue readable while leaving the run open to
# inspection behind a "show" toggle.
drop_progress() {
  [ -f "$PIDS_FILE" ] || return 0
  while read -r nid; do
    [ -z "$nid" ] && continue
    gh api graphql -f query='mutation($id: ID!) {
      minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) {
        minimizedComment { isMinimized }
      }
    }' -f id="$nid" >/dev/null 2>&1
  done < "$PIDS_FILE"
  rm -f "$PIDS_FILE"
  return 0
}

# Runs on every exit, including the kill poll.sh sends to interrupt a turn.
cleanup_run() {
  [ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null
  drop_progress
  rm -f "$PIDFILE" "$CPIDFILE"
  return 0
}
trap cleanup_run EXIT

# Defined before first use: the usage-limit branch below calls fmt_eta.
fmt_tokens() {
  awk -v n="${1:-0}" 'BEGIN { if (n >= 1000) printf "%.1fk", n/1000; else printf "%d", n }'
}

# Seconds until an epoch, as a human duration.
fmt_eta() {
  awk -v target="${1:-0}" -v now="$(date +%s)" 'BEGIN {
    s = target - now
    if (s <= 0) { printf "now"; exit }
    h = int(s / 3600); m = int((s % 3600) / 60)
    if (h >= 24) printf "%dd%dh", int(h / 24), h % 24
    else if (h > 0) printf "%dh%02dm", h, m
    else printf "%dm", m
  }'
}

SANDBOX_SETTINGS="$DIR/sandbox-settings.json"
[ -f "$SANDBOX_SETTINGS" ] || die "Missing $SANDBOX_SETTINGS. Re-run setup.sh."

log "issue #$NUM  branch=$BRANCH  session=$SESSION_ID  started=$STARTED  model=$MODEL effort=$EFFORT"

# ---------------------------------------------------------------- worktree
git -C "$CLONE" fetch --prune origin

if [ ! -e "$WT/.git" ]; then
  mkdir -p "$WORKTREE_ROOT"
  if git -C "$CLONE" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git -C "$CLONE" worktree add "$WT" -B "$BRANCH" "origin/$BRANCH"
  else
    git -C "$CLONE" worktree add "$WT" -b "$BRANCH" "origin/$DEFAULT_BRANCH"
  fi
fi

# Keep build junk out of the agent's commits, without touching the repo's own
# .gitignore. Applies to fresh and pre-existing worktrees alike.
git -C "$WT" config core.excludesFile "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/default-ignore"

# Reconcile with the remote before Claude runs. Claude cannot do this itself:
# the sandbox withholds its git credentials, so a worktree left behind the
# remote strands it — it works against stale code, and the push at the end is
# rejected as non-fast-forward, which used to kill this script mid-run and
# leave the issue with no reply at all.
if git -C "$CLONE" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  DIRTY="$(git -C "$WT" status --porcelain)"
  AHEAD="$(git -C "$WT" log --oneline "origin/$BRANCH..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
  BEHIND="$(git -C "$WT" log --oneline "HEAD..origin/$BRANCH" 2>/dev/null | wc -l | tr -d ' ')"

  if [ -n "$DIRTY" ]; then
    # Uncommitted edits are almost always an interrupted turn's work. Never
    # destroy them; being behind is the lesser problem.
    log "issue #$NUM: worktree is dirty, keeping it (ahead=$AHEAD behind=$BEHIND)"
  elif [ "$AHEAD" -gt 0 ] && [ "$BEHIND" -gt 0 ]; then
    log "issue #$NUM: diverged (ahead=$AHEAD behind=$BEHIND), rebasing onto origin/$BRANCH"
    if ! git -C "$WT" rebase "origin/$BRANCH" >/dev/null 2>&1; then
      git -C "$WT" rebase --abort >/dev/null 2>&1 || true
      gh issue comment "$NUM" --repo "$REPO" --body "$AGENT_MARKER
$AGENT_HEADER

This branch has diverged from its remote and the two sides conflict, so I
stopped before touching anything.

\`$BRANCH\` has $AHEAD local commit(s) and $BEHIND remote commit(s) that a
rebase cannot reconcile on its own. Resolve it by hand, then comment here again:

\`\`\`bash
git fetch origin && git checkout $BRANCH && git rebase origin/$BRANCH
\`\`\`" >/dev/null 2>&1 || true
      die "issue #$NUM: rebase conflict against origin/$BRANCH"
    fi
  elif [ "$AHEAD" -gt 0 ]; then
    log "issue #$NUM: $AHEAD local commit(s) not yet on origin/$BRANCH, keeping them"
  else
    git -C "$WT" reset --hard "origin/$BRANCH"
  fi
fi

BEFORE="$(git -C "$WT" rev-parse HEAD)"

# ---------------------------------------------------------------- prompt
INTERRUPT_NOTE=""
if [ "$(echo "$STATE" | jq -r '.interrupted // false')" = "true" ]; then
  INTERRUPT_NOTE="
- Your previous turn was cut off part-way because the human sent a new message.
  The working tree may hold half-finished edits from it. Check \`git status\` and
  the diff first, then finish or undo them as the new message requires."
fi

FULL_PROMPT="$(mktemp)"
{
  cat "$PROMPT_FILE"
  cat <<EOF

---
Context (added by the automation, not written by the human):
- Repository: $REPO
- You are in a git worktree on branch \`$BRANCH\`.
- Base branch: \`$DEFAULT_BRANCH\`.
- This worktree is already reconciled with the remote: fetched, and reset or
  rebased onto \`origin/$BRANCH\` before you were started. Read it with
  \`git log --oneline $DEFAULT_BRANCH..HEAD\` and the diff — the human may have
  pushed commits since your last turn — but do NOT fetch, pull, merge or rebase
  it yourself. Git authentication is unreliable in here — the credential helper
  cannot write — and a merge commit created mid-turn breaks the push that
  follows. Syncing is the automation's job, outside the sandbox.
- Edit files directly. Do NOT commit, push, or open a pull request, and do NOT
  comment on the issue yourself (no \`gh issue comment\`, no \`gh api\` on
  /comments).
  The automation posts everything you say and handles all git operations.$INTERRUPT_NOTE
- Your reply is posted straight into GitHub issue #$NUM as a comment. Write it
  the way you would answer a colleague there.
- Reply in the language the human used in this issue. If they wrote Chinese,
  answer in Chinese.
- Do NOT open with a report header such as "Summary for issue #N" or
  "## Summary". Just say what you changed and what you need from them, if
  anything. Keep it short.
EOF
} > "$FULL_PROMPT"

# ---------------------------------------------------------------- claude
OUT="$(mktemp)"
ERRF="$(mktemp)"
MODEL_LABEL="${MODEL#claude-}-$EFFORT"
rm -f "$PIDS_FILE"

# Post one comment, recording the node id GraphQL needs to collapse it later.
post_progress() {
  local nid
  nid="$(gh api "repos/$REPO/issues/$NUM/comments" -f body="$1" --jq .node_id 2>/dev/null || echo '')"
  [ -n "$nid" ] && echo "$nid" >> "$PIDS_FILE"
  return 0
}

# Each paragraph Claude writes, one JSON string per line. Editing a comment
# sends no notification, so every paragraph gets its own comment instead.
segments() {
  jq -Rr 'fromjson? // empty
          | select(.type=="assistant") | .message.content[]?
          | select(.type=="text") | .text
          | select(test("^[[:space:]]*$") | not) | @json' "$OUT" 2>/dev/null || true
}

post_progress "$AGENT_MARKER
$AGENT_HEADER

Picked this up — running $MODEL_LABEL…"

# Watch the stream and post whatever is new. Tool calls stay out — the point is
# to read along, not to watch a call log.
(
  posted=0
  while true; do
    sleep "${HEARTBEAT_INTERVAL:-10}"
    total="$(segments | wc -l | tr -d ' ')"
    # Never post the newest paragraph. Claude's closing summary is both its last
    # paragraph and the final result, so posting it here would duplicate the
    # real reply — same text, twice, two notifications. Holding one back means
    # a paragraph only goes out once a later one exists, and the last one never
    # does.
    total=$((total - 1))
    [ "$total" -le "$posted" ] && continue
    i=$((posted + 1))
    while [ "$i" -le "$total" ]; do
      seg="$(segments | sed -n "${i}p" | jq -r . 2>/dev/null || true)"
      [ -n "$seg" ] && post_progress "$AGENT_MARKER
$AGENT_HEADER

$(printf '%s' "$seg" | tail -c 60000)"
      i=$((i + 1))
    done
    posted=$total
  done
) &
HB_PID=$!

if session_exists "$SESSION_ID"; then
  RESUME_ARGS="--resume $SESSION_ID"
else
  RESUME_ARGS="--session-id $SESSION_ID"
fi

set +e
# Backgrounded on purpose: poll.sh kills this pid to interrupt a running turn.
# `set -m` puts the child in its own process group, so poll.sh can signal the
# group and take Claude's own subprocesses down with it.
set -m
( cd "$WT" && exec "$CLAUDE_ISSUE_CLI" -p \
    $RESUME_ARGS \
    --output-format stream-json --verbose \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --settings "$SANDBOX_SETTINGS" \
    --permission-mode "$PERMISSION_MODE" < "$FULL_PROMPT" ) > "$OUT" 2>"$ERRF" &
CLAUDE_PID=$!
set +m
echo "$CLAUDE_PID" > "$CPIDFILE"
wait "$CLAUDE_PID"
RC=$?
set -e
rm -f "$CPIDFILE"

# Stop posting. The progress comments stay up until the real reply is in, so the
# issue is never momentarily blank.
[ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null; HB_PID=""

# Killed by poll.sh: leave the half-finished tree alone and say nothing on the
# issue. The next turn picks up with the human's new message.
INT_TOKEN="$DIR/state/issue-$NUM.interrupt"
if [ $RC -ge 128 ] && [ -f "$INT_TOKEN" ]; then
  rm -f "$INT_TOKEN"
  # Only mark the session resumable if Claude got far enough to write one;
  # otherwise --resume would fail on the next turn.
  if session_exists "$SESSION_ID"; then ST=true; else ST=false; fi
  read_state "$REPO" "$NUM" | jq --argjson st "$ST" '.started = $st | .interrupted = true' \
    | write_state "$REPO" "$NUM"
  log "issue #$NUM interrupted (rc=$RC), leaving the tree as-is"
  exit 0
fi
rm -f "$INT_TOKEN"
# A signal nobody asked for — OOM killer, a stray kill — is a failure, not a
# clean stop. Falling through reports it instead of silently parking the issue.

RESULT_LINE="$(jq -Rc 'fromjson? // empty | select(.type=="result")' "$OUT" 2>/dev/null | tail -1)"

if [ $RC -ne 0 ] || [ -z "$RESULT_LINE" ]; then
  # Hitting the usage limit is not a defect in the task, and retrying before the
  # window resets only burns turns. Say when it comes back, and exit 75 so the
  # failure counter leaves the issue alone.
  if grep -qiE 'rate.?limit|usage limit|quota|429' "$OUT" "$ERRF" 2>/dev/null; then
    RESET_AT="$(jq -Rr 'fromjson? // empty
                        | select(.type=="rate_limit_event")
                        | .rate_limit_info.resetsAt // empty' "$OUT" 2>/dev/null | tail -1)"
    WHEN=""
    [ -n "$RESET_AT" ] && WHEN=" It resets in $(fmt_eta "$RESET_AT")."
    gh issue comment "$NUM" --repo "$REPO" --body "$AGENT_MARKER
$AGENT_HEADER

Stopped: this account hit its usage limit.$WHEN

Nothing is broken and nothing was lost — comment here again once the window
resets and I will pick up where this left off." >/dev/null 2>&1 || true
    log "issue #$NUM: usage limit reached, not counting as a failure"
    exit 75
  fi

  gh issue comment "$NUM" --repo "$REPO" --body "$AGENT_MARKER
$AGENT_HEADER

**Run failed** (exit $RC).

\`\`\`
$(tail -c 3000 "$ERRF" 2>/dev/null; tail -c 1000 "$OUT")
\`\`\`
Log: \`$DIR/logs/issue-$NUM.log\`"
  die "claude failed for issue #$NUM"
fi

IS_ERR="$(echo "$RESULT_LINE" | jq -r '.is_error // false')"
RESULT="$(echo "$RESULT_LINE" | jq -r '.result // ""')"
TURNS="$(echo "$RESULT_LINE" | jq -r '.num_turns // 0')"

# What the last API call of this turn had to send: the conversation so far.
# A turn makes several calls and `usage` sums them, so the last iteration is the
# honest figure for "how full is this session" — the number that says when to
# start a fresh issue rather than let compaction quietly degrade the thread.
CTX_TOKENS="$(echo "$RESULT_LINE" | jq -r '
  ((.usage.iterations // []) | last) // .usage // {}
  | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
  ' 2>/dev/null || echo 0)"
OUT_TOKENS="$(echo "$RESULT_LINE" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)"

# No context threshold here on purpose: the window size depends on the model and
# the account (200k, 1M), the run cannot discover it, and a hardcoded guess ages
# into a lie. The number is reported; the reader knows their own ceiling.
USAGE_LINE=""
if [ "${CTX_TOKENS:-0}" -gt 0 ] 2>/dev/null; then
  USAGE_LINE="

<sub>context $(fmt_tokens "$CTX_TOKENS") · $(fmt_tokens "$OUT_TOKENS") out</sub>"
fi

read_state "$REPO" "$NUM" \
  | jq --arg s "$SESSION_ID" '.started = true | .session_id = $s | .interrupted = false' \
  | write_state "$REPO" "$NUM"

if [ "$IS_ERR" = "true" ]; then
  gh issue comment "$NUM" --repo "$REPO" --body "$AGENT_MARKER
$AGENT_HEADER

**Claude returned an error**

$RESULT"
  die "claude error on issue #$NUM: $RESULT"
fi

# ---------------------------------------------------------------- commit
CHANGED=no
if [ -n "$(git -C "$WT" status --porcelain)" ]; then
  git -C "$WT" add -A
  git -C "$WT" -c user.name="claude-agent" \
      -c user.email="claude-agent@localhost" \
      commit -q -m "issue #$NUM: $(head -c 60 "$PROMPT_FILE" | tr '\n' ' ')"
  CHANGED=yes
fi

AFTER="$(git -C "$WT" rev-parse HEAD)"
PR_LINE="

_No file changes this turn._"

if [ "$BEFORE" != "$AFTER" ]; then
  if ! PUSH_ERR="$(git -C "$WT" push -u origin "$BRANCH" 2>&1)"; then
    gh issue comment "$NUM" --repo "$REPO" --body "$AGENT_MARKER
$AGENT_HEADER

The work is done but I could not push it — the commit is sitting in my local
worktree on \`$BRANCH\`.

\`\`\`
$(printf '%s' "$PUSH_ERR" | tail -c 1200)
\`\`\`

Nothing is lost. Comment here again once the branch is pushable and I will
retry." >/dev/null 2>&1 || true
    die "issue #$NUM: push to $BRANCH failed"
  fi
  if ! gh pr view "$BRANCH" --repo "$REPO" >/dev/null 2>&1; then
    TITLE="$(gh issue view "$NUM" --repo "$REPO" --json title --jq .title 2>/dev/null || echo "issue #$NUM")"
    # A PR is a convenience; the commits are already pushed. Opening one can
    # legitimately fail — "No commits between main and <branch>" after a rebase
    # leaves nothing to compare — and that must not abort the turn before its
    # reply is posted.
    if ! PR_ERR="$(gh pr create --repo "$REPO" --head "$BRANCH" --base "$DEFAULT_BRANCH" \
         --title "issue #$NUM: $TITLE" --body "Closes #$NUM" 2>&1)"; then
      log "issue #$NUM: could not open a PR ($(printf '%s' "$PR_ERR" | tail -c 200))"
    fi
  fi
  # Work was pushed; say so even if the PR lookup itself fails.
  PR_LINE="

Pushed to \`$BRANCH\`."
  PR_URL="$(gh pr view "$BRANCH" --repo "$REPO" --json url --jq .url 2>/dev/null || echo '')"
  if [ -n "$PR_URL" ]; then
    PR_LINE="

**PR:** $PR_URL  \`$BRANCH\`"
  fi
fi

# ---------------------------------------------------------------- reply
# The reply is the only thing the human is waiting for. Losing it silently —
# a network blip, a body GitHub rejects — leaves the issue looking abandoned
# with the work already pushed, so say *something* even when the real reply
# cannot be posted.
REPLY_BODY="$AGENT_MARKER
$AGENT_HEADER

$RESULT
$PR_LINE$USAGE_LINE"
if ! gh issue comment "$NUM" --repo "$REPO" --body "$REPLY_BODY" >/dev/null 2>&1; then
  log "issue #$NUM: posting the reply failed, retrying once"
  sleep 3
  if ! gh issue comment "$NUM" --repo "$REPO" --body "$REPLY_BODY" >/dev/null 2>&1; then
    log "issue #$NUM: reply could not be posted; falling back to a short notice"
    gh issue comment "$NUM" --repo "$REPO" --body "$AGENT_MARKER
$AGENT_HEADER

The turn finished but its reply could not be posted (GitHub rejected it, twice).
The work itself is safe.$PR_LINE

Full text: \`$DIR/logs/issue-$NUM.log\`" >/dev/null 2>&1 \
      || log "issue #$NUM: the fallback notice failed too"
  fi
fi

# Real reply is in; fold the progress comments away.
drop_progress

rm -f "$FULL_PROMPT" "$OUT" "$ERRF"
log "issue #$NUM done (changed=$CHANGED turns=$TURNS)"
