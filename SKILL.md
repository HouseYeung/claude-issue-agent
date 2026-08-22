---
name: claude-issue-agent
description: Drive local Claude Code from GitHub issues. Use to set it up, start or stop the watcher, add a repo, pick a model per issue, or fix it when it stops replying.
license: MIT
compatibility: macOS or Linux. Requires gh (authenticated), jq, git, and the claude CLI (authenticated). Unattended operation uses launchd on macOS, a systemd user unit on Linux.
metadata:
  version: "1.0"
---

# Claude Issue Agent

Open a GitHub issue from a phone; the local machine picks it up, writes code,
pushes a branch, opens a PR, and replies on the issue. Comment again to continue
the same session — or to interrupt a turn that is still running.

## Setting up: ask three questions first

On first use, or when adding a repository, **ask with AskUserQuestion before
running anything**. Do not guess and do not skip.

1. **Machine codename** — becomes the routing label `claude-<codename>`. Short,
   memorable, identifies this machine (`ukk`, `home`, `mbp`). Lowercase letters,
   digits, hyphens only.
2. **Permission mode** — default `bypassPermissions`. See the table below.
3. **Repository** — `owner/repo`, one the user can write to. `setup.sh` refuses
   a public repo unless the user explicitly overrides it, because on a public
   repo any GitHub account could open an issue and issues run as prompts here.

| Mode | Behavior | Measured |
|---|---|---|
| `bypassPermissions` (default) | Everything passes | Fastest, no stalls — ⚠️ the Write tool reaches the home directory; the sandbox stops only Bash |
| `acceptEdits` | Edits inside the working directory pass; outside is refused | 0 permission stalls, and writes stay in the worktree |
| `auto` | Classifier judges each call | Too strict — refuses Writes inside the working directory, forcing detours |

Then run:

```bash
AGENT_CODENAME=<codename> PERMISSION_MODE=<mode> \
  ~/.claude/skills/claude-issue-agent/scripts/setup.sh <owner/repo>
```

Pass an existing local clone as a second argument instead of cloning again.

`ALLOWED_USERS` restricts who can drive the machine to a space-separated list of
GitHub logins; issues and comments from anyone else are ignored. It is optional
on a private repo and mandatory when overriding the public-repo refusal:

```bash
ALLOWED_USERS="alice bob" ALLOW_PUBLIC_REPO=1 AGENT_CODENAME=<codename> \
  ~/.claude/skills/claude-issue-agent/scripts/setup.sh <owner/repo>
```

`setup.sh` checks the environment itself (gh login, jq, claude, repo access).
**Report whatever it says and tell the user how to fix it. Do not run a test
task to verify.** The two common failures are an unauthenticated `gh`
(`gh auth login -h github.com`, or `gh auth refresh -h github.com` when the
account is already there) and an expired claude login (run `claude` once
interactively).

Then install the background watcher and **stop there** — do not open a test issue:

```bash
~/.claude/skills/claude-issue-agent/scripts/ctl.sh install <owner/repo>
```

Tell the user it is running and that issues need the `claude-<codename>` label.

## When the user asks to shut it down

```bash
~/.claude/skills/claude-issue-agent/scripts/ctl.sh uninstall <owner/repo>
~/.claude/skills/claude-issue-agent/scripts/ctl.sh stop <owner/repo>
```

`uninstall` removes the service (launchd job on macOS, systemd user unit on
Linux); `stop` takes the service down first — otherwise it would restart what
`stop` kills — then clears strays the pid file lost track of.

On Linux the unit needs lingering so it survives with no login session;
`install` enables it, and falls back to telling you to run
`sudo loginctl enable-linger <user>` when it cannot. Under WSL, nothing starts
the distribution at Windows boot, so also register a logon task on the Windows
side: `schtasks /create /tn "WSL <distro> boot" /tr "wsl.exe -d <distro> -u root
-e /bin/true" /sc onlogon /rl highest`.

## Labels decide everything

| Label | Role | Required |
|---|---|---|
| `claude-<codename>` | Which machine takes the work | Yes |
| `sonnet-5-low` and friends | Which model, how much thinking | No |

An issue without a routing label is **never touched** by this machine, so several
machines can watch one repository under different codenames.

Model labels are `<model>` or `<model>-<effort>`; no suffix means `high`.
Models: `opus-5`, `opus-4-6`, `fable-5`, `sonnet-5`, `haiku-4-5`.
Efforts: `low`, `medium`, `high`, `xhigh`, `max`. The `-6` in `opus-4-6` is part
of the name, not an effort. All 25 combinations are accepted.

`setup.sh` creates **only** the routing label — a repository's label list is
shared with everyone working in it, and 25 model labels is not this tool's to
spend. Create the ones actually wanted, by name:

```bash
~/.claude/skills/claude-issue-agent/scripts/ctl.sh labels <owner/repo> sonnet-5-low opus-5
```

With no names it creates all 25. Unknown names are reported and skipped.

**The model is pinned when the issue starts.** Relabeling later changes nothing;
open a new issue to switch models.

## Three things that constrain behavior

**One issue is one session.** Issue #12 keeps its full history on branch
`claude/issue-12` in its own worktree; issue #13 knows nothing about it. The
session id is `md5("owner/repo#12")`, so it survives lost state and reboots.
New context means a new issue.

**Any new comment interrupts a running turn.** No `/stop` keyword. Half-finished
edits stay in the worktree uncommitted and no result is posted — progress
comments already sent stay, collapsed — and the next turn takes the new comment
as input within `BUSY_INTERVAL` (10s default).
A comment starting with `//` is a note: never a prompt, never an interruption,
so you can think out loud on an issue without waking anything up.

**Progress arrives as it happens.** On pickup the agent posts a "picked this up" comment, then one
comment per paragraph Claude writes — new comments, not edits, because GitHub
sends no notification for an edit. Tool calls are left out; only the prose.
When the turn ends the real reply is posted and every progress comment is
collapsed, so the issue reads clean but the run stays open to inspection.
The newest block is always held back — Claude's closing summary is also the
final result, and posting both would duplicate it. Progress is best-effort: a
run that finishes between polls (`HEARTBEAT_INTERVAL`, 10s) may show little or
none of it.

Claude never commits, pushes, opens a PR, or comments on the issue: its prompt
forbids those specifically. Reading git is expected — the prompt tells it to run
`git log` and read the diff before assuming where the code stands.

**The sandbox protects the machine, not the repository.** Bash writes only
inside its worktree and cannot read `~/.ssh`, `~/.aws`, or `~/.gnupg`, but the
network is open — and under the default `bypassPermissions` the Write tool is
ungated and reaches the home directory. Anyone who can apply the routing label
can make this machine run code, so use it only on private repositories with
trusted collaborators.

## References

- `references/operations.md` — day-to-day commands, tuning, layout, and how to
  hand edited code back to the agent
- `references/troubleshooting.md` — what to do when it stops responding
