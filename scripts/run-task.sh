#!/usr/bin/env bash
# Run one Claude turn for one issue, then push the code and reply on GitHub.
# Usage: run-task.sh <owner/repo> <issue-number> <prompt-file>
set -euo pipefail
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

# Pull in anything pushed to this branch by hand, so Claude builds on it — but
# only when there is nothing here to lose. A hard reset over an interrupted
# turn's edits, or over a commit whose push failed, destroys work with no trace.
if git -C "$CLONE" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  if [ -n "$(git -C "$WT" status --porcelain)" ]; then
    log "issue #$NUM: worktree is dirty, keeping it instead of resetting to origin/$BRANCH"
  elif [ -n "$(git -C "$WT" log --oneline "origin/$BRANCH..HEAD" 2>/dev/null)" ]; then
    log "issue #$NUM: local commits not on origin/$BRANCH, keeping them"
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
- The human may have pushed their own commits to this branch since your last
  turn. Run \`git log --oneline $DEFAULT_BRANCH..HEAD\` and read the diff before
  you assume the code is where you left it.
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
ERRF="$OUT.err"
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
( cd "$WT" && exec claude -p "$(cat "$FULL_PROMPT")" \
    $RESUME_ARGS \
    --output-format stream-json --verbose \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --settings "$SANDBOX_SETTINGS" \
    --permission-mode "$PERMISSION_MODE" < /dev/null ) > "$OUT" 2>"$ERRF" &
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
  git -C "$WT" push -q -u origin "$BRANCH"
  if ! gh pr view "$BRANCH" --repo "$REPO" >/dev/null 2>&1; then
    TITLE="$(gh issue view "$NUM" --repo "$REPO" --json title --jq .title)"
    gh pr create --repo "$REPO" --head "$BRANCH" --base "$DEFAULT_BRANCH" \
      --title "issue #$NUM: $TITLE" --body "Closes #$NUM" >/dev/null
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
gh issue comment "$NUM" --repo "$REPO" --body "$AGENT_MARKER
$AGENT_HEADER

$RESULT
$PR_LINE"

# Real reply is in; fold the progress comments away.
drop_progress

rm -f "$FULL_PROMPT" "$OUT" "$ERRF"
log "issue #$NUM done (changed=$CHANGED turns=$TURNS)"
