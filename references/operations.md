# Operations

## Commands

Every command takes `<owner/repo>`.

| Goal | Command |
|---|---|
| Status and all sessions | `ctl.sh status` |
| Follow the log | `ctl.sh logs` |
| Run detached, unmanaged (survives the terminal, no restart on crash or reboot) | `ctl.sh start` |
| Stop, including strays | `ctl.sh stop` |
| Run unattended | `ctl.sh install` |
| Remove the service | `ctl.sh uninstall` |
| Create model labels (opt-in) | `ctl.sh labels <repo> [name...]` |
| Add a repository | `setup.sh` again, then `ctl.sh install` |
| Known cap | at most 30 open routed issues are examined per poll |
| Add a machine to the same repository | run `setup.sh` there with a **different** `AGENT_LABEL` |

Scripts live in `scripts/`.

## Tuning

`$CLAUDE_ISSUE_AGENT_HOME/<owner>__<repo>/config.env`:

| Key | Default | Meaning |
|---|---|---|
| `AGENT_LABEL` | `claude-<hostname>` | The routing label. `setup.sh` derives it from `AGENT_CODENAME`; edit here only to repoint an existing install |
| `ALLOWED_USERS` | empty | Space-separated GitHub logins allowed to drive this machine. Empty means anyone who can label an issue in the repo — safe only while it stays private |
| `PERMISSION_MODE` | `bypassPermissions` | `acceptEdits`, `bypassPermissions`, or `auto` |
| `POLL_INTERVAL` | `60` | Seconds between polls while idle |
| `BUSY_INTERVAL` | `10` | Seconds between polls while a turn runs — sets how fast an interruption lands |
| `HEARTBEAT_INTERVAL` | `10` | Seconds between checks for new paragraphs to post. Lower shows more of a short run, at more API calls |
| `DEFAULT_MODEL` | `claude-opus-5` | Used when no model label is present |
| `DEFAULT_EFFORT` | `high` | Used when a model label carries no effort suffix |
| `BRANCH_PREFIX` | `claude/issue-` | Branch naming |

Run `ctl.sh stop` then `ctl.sh start` after editing.

## Who can trigger a run

`setup.sh` refuses a public repository: an issue is a prompt this machine runs,
and on a public repo anyone could open one. Overriding it takes both
`ALLOW_PUBLIC_REPO=1` and a non-empty `ALLOWED_USERS`.

`ALLOWED_USERS` is a space-separated list of GitHub logins, matched against the
issue's author and against the author of each follow-up comment — not against
whoever applied the routing label. When set, issues opened by anyone else are
ignored entirely, and their comments neither become prompts nor interrupt a
running turn. Leaving it empty trusts everyone who can label an
issue in the repository, which is why a private repo is the default requirement.

## Sandbox

`<instance>/sandbox-settings.json`:

```json
{
  "sandbox": {
    "enabled": true,
    "network": { "allowedDomains": ["*"] },
    "filesystem": { "denyRead": ["~/.ssh", "~/.aws", "~/.gnupg"] }
  }
}
```

Write access needs no configuration — an enabled sandbox already confines writes
to the working directory. Widen it with `filesystem.allowWrite`; narrow the
network by replacing `["*"]` with explicit domains.

## Handing edited code back

```bash
git fetch origin && git checkout claude/issue-12
```

Edit, `git push`, then comment on issue #12. The next turn runs
`git reset --hard origin/claude/issue-12` first, so Claude sees the pushed work,
and its prompt says to read `git log` and the diff before assuming anything.

## Layout

```
./
  SKILL.md
  default-ignore           Junk the agent never commits (__pycache__ and such),
                           attached per-worktree via core.excludesFile so the
                           repository's own .gitignore is untouched
  references/
    operations.md
    troubleshooting.md
  scripts/
    lib.sh                 Shared helpers, deterministic session ids, label parsing
    setup.sh               Configure a repository, create labels, write the sandbox
    poll.sh                Polling, label routing, interruption, failure backoff
    run-task.sh            One Claude turn, then commit/push/PR/reply
    ctl.sh                 start stop status logs install uninstall

$CLAUDE_ISSUE_AGENT_HOME/<owner>__<repo>/
  config.env               Per-repository configuration
  sandbox-settings.json    Claude's sandbox boundary
  repo/                    Local clone
  worktrees/issue-N/       Isolated working directory per issue
  state/issue-N.json       Session id, model, comment watermark, failure count,
                           interrupted flag
  logs/                    poll.log and issue-N.log
```
