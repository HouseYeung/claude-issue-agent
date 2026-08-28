# claude-issue-agent

Drive local Claude Code from GitHub issues. Keep developing while away from the
machine, without using Claude's cloud or remote sessions.

```
You (phone) open an issue, label it claude-ukk
        │
        ▼
poll.sh watches GitHub from your machine
        │
        ▼
run-task.sh
   1. git fetch, pulling your own commits into the worktree
   2. claude -p  ──first turn --session-id / later --resume──> one session
   3. git commit + push to claude/issue-<N>
   4. open a PR on the first push
   5. post Claude's summary back to the issue
        │
        ▼
You (phone) read the PR, comment → next turn
        Comment mid-run → the turn is cut off and redirected
```

## What it does

- **Label routing** — `claude-<codename>` decides which machine takes the work,
  so several machines can watch one repository
- **Label picks the model** — `sonnet-5-low`, `opus-4-6-max`, one tap on a phone.
  Setup creates only the routing label; model labels are opt-in via
  `ctl.sh labels`, so the repository's shared label list stays yours
- **One issue, one session** — the session id is `md5(repo#N)`, so it survives
  lost state and reboots
- **Interruptible** — comment while a turn runs and it is cut off within ~10s,
  continuing the same session in a new direction; prefix a comment with `//` to
  leave a note that neither triggers nor interrupts anything
- **Live progress** — each text block Claude emits is posted as its own comment
  so it actually notifies, then collapsed once the real reply lands
- **Sandboxed** — Bash confined to the issue's worktree, network open,
  `~/.ssh` `~/.aws` `~/.gnupg` unreadable

## Install

Add the public Skill repository in CC Switch, install `claude-issue-agent`, and enable it for the required clients. The installed copy is the runtime source; do not link a development checkout directly.

Then ask an agent to set it up. It asks three questions — machine codename,
permission mode, repository — and configures everything.

Manual setup:

```bash
AGENT_CODENAME=ukk PERMISSION_MODE=bypassPermissions \
  scripts/setup.sh <owner/repo>
scripts/ctl.sh install <owner/repo>
```

See [SKILL.md](SKILL.md) for the full contract,
[references/operations.md](references/operations.md) for daily use, and
[references/troubleshooting.md](references/troubleshooting.md) when it stops
responding.

## Requirements

macOS or Linux. Unattended operation uses a launchd job on macOS and a systemd
user unit (with lingering) on Linux. Needs `gh` (authenticated), `jq`, `git`,
and the `claude` CLI (authenticated).

## Security

The sandbox confines Bash to the issue's worktree and hides `~/.ssh`, `~/.aws`
and `~/.gnupg`. The default permission mode is `bypassPermissions`, so the Write
tool itself is not gated and can reach the home directory — set
`PERMISSION_MODE=acceptEdits` if you want writes outside the worktree refused.
And **anyone who can apply the routing label can make your machine run code** —
use this only on private repositories with collaborators you trust.

## License

MIT
