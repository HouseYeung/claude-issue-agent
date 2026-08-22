# Troubleshooting

## Nothing happens

```bash
~/.claude/skills/claude-issue-agent/scripts/ctl.sh status <owner/repo>
```

`STOPPED` → `ctl.sh start` or `ctl.sh install`. `RUNNING` → read `ctl.sh logs`;
almost always the issue is missing its `claude-<codename>` routing label. Check:

```bash
gh issue view <N> --repo <owner/repo> --json labels
```

## A reply says 401 / authenticate

The claude CLI login expired. Run `claude` once interactively, `/exit`, then
restart the watcher. The `gh` login expires separately. Refresh an existing account:

```bash
gh auth refresh -h github.com
```

If there is no account at all, log in instead:

```bash
gh auth login -h github.com
```

## It gave up after three failures

Deliberate, so a hard error cannot flood the log. Clear the counter after
fixing the cause:

```bash
D=~/.claude/claude-issue-agent/<owner>__<repo>
jq '.fails = 0' $D/state/issue-<N>.json > /tmp/s.json && mv /tmp/s.json $D/state/issue-<N>.json
```

## The same comment fires repeatedly

The watermark is corrupt. Stop the watcher, delete that issue's state, start
again. This does **not** clear the conversation: the session id is derived from
the issue number, so the next run resumes the same session. See "Starting an
issue over from scratch" for a real reset.

```bash
rm ~/.claude/claude-issue-agent/<owner>__<repo>/state/issue-<N>.json
```

## `Session ID ... is already in use`

State claims the issue never started while a session file exists on disk. The
scripts glob for the session file rather than trusting state, so this should not
occur; if it does, delete the state file and start over.

## Startup says a watcher is still alive

Strays from an earlier run. `ctl.sh stop` clears them with `pkill -f`, then
`start`. To confirm:

```bash
pgrep -fl 'poll.sh <owner/repo>'
```

## Starting an issue over from scratch

The simplest real reset is a new issue: the session id, branch and worktree all
derive from the issue number, so a new number is a clean slate.

To reset in place, every derived thing has to go — state, the Claude session,
the worktree, and both branches. Missing any one of them leaves the old
conversation or the old code in play.

```bash
D=~/.claude/claude-issue-agent/<owner>__<repo>
N=<issue-number>
~/.claude/skills/claude-issue-agent/scripts/ctl.sh stop <owner/repo>
git -C $D/repo worktree remove --force $D/worktrees/issue-$N
git -C $D/repo branch -D claude/issue-$N
git -C $D/repo push origin --delete claude/issue-$N
rm -f $D/state/issue-$N.json
rm -f ~/.claude/projects/*/"$(bash -c '. ~/.claude/skills/claude-issue-agent/scripts/lib.sh; issue_uuid "<owner/repo>#'$N'"')".jsonl
```

## Git errors after moving the data directory

Worktrees record absolute paths:

```bash
D=~/.claude/claude-issue-agent/<owner>__<repo>
git -C $D/repo worktree repair $D/worktrees/*
```

## Claude reports that its own git fetch or push failed

Expected. The sandbox does not expose its network credentials. `run-task.sh`
does all fetching and pushing outside the sandbox, so nothing is lost. Claude
falls back to `gh api` when it wants remote state.

## An interruption did not land

Interruptions are checked every `BUSY_INTERVAL` (10s default). The log should
show `issue #N: interrupted by a new comment`. If it does not, the watcher is
running old code — `ctl.sh stop` then `start`.

## Per-issue detail

```bash
tail -f ~/.claude/claude-issue-agent/<owner>__<repo>/logs/issue-<N>.log
```
