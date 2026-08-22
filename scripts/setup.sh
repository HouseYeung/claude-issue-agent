#!/usr/bin/env bash
# One-time setup for one repository.
# Usage: setup.sh <owner/repo> [/path/to/local/clone]
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="${1:?usage: setup.sh <owner/repo> [local-clone-path]}"
CLONE="${2:-}"

command -v git  >/dev/null || die "git not found."
command -v gh   >/dev/null || die "gh not found. brew install gh"
command -v jq   >/dev/null || die "jq not found. brew install jq"
command -v claude >/dev/null || die "claude not found."

gh auth status >/dev/null 2>&1 \
  || die "gh is not authenticated. Run: gh auth login -h github.com
(if the account is already there but its credentials expired: gh auth refresh -h github.com)"

PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
case "$PERMISSION_MODE" in
  acceptEdits|bypassPermissions|auto) ;;
  *) die "PERMISSION_MODE must be acceptEdits, bypassPermissions or auto (got: $PERMISSION_MODE)" ;;
esac

# Verify the repo exists and we can reach it.
gh repo view "$REPO" --json nameWithOwner,isPrivate >/dev/null \
  || die "Cannot read $REPO. Check the name and your gh permissions."

# Resolved before the public-repo check below, which quotes it in an error.
OWNER_LOGIN="$(gh api user --jq .login)"

# A public repo means any GitHub account can open an issue, and an issue is a
# prompt this machine executes. Refuse by default; ALLOW_PUBLIC_REPO=1 is a
# deliberate override for someone who has read that sentence.
if [ "$(gh repo view "$REPO" --json isPrivate --jq .isPrivate)" != "true" ]; then
  if [ "${ALLOW_PUBLIC_REPO:-0}" != "1" ]; then
    die "$REPO is public. Anyone could open an issue, and issues run as prompts
on this machine. Use a private repo, or set ALLOWED_USERS and re-run with
ALLOW_PUBLIC_REPO=1 if you accept that risk."
  fi
  [ -n "${ALLOWED_USERS:-}" ] \
    || die "ALLOW_PUBLIC_REPO=1 requires ALLOWED_USERS, or every GitHub account
could drive this machine. Example: ALLOWED_USERS=\"$OWNER_LOGIN\""
  log "WARNING: $REPO is public. Only these users can trigger it: $ALLOWED_USERS"
fi

DIR="$(inst_dir "$REPO")"
mkdir -p "$DIR/state" "$DIR/logs"

# Local clone: reuse the given one, else clone into the instance dir.
if [ -z "$CLONE" ]; then
  CLONE="$DIR/repo"
  if [ ! -d "$CLONE/.git" ]; then
    log "Cloning $REPO into $CLONE"
    gh repo clone "$REPO" "$CLONE"
  fi
else
  CLONE="$(cd "$CLONE" && pwd)"
  [ -d "$CLONE/.git" ] || die "$CLONE is not a git repo."
fi

# The codename names the machine; the label is always claude-<codename>. Taking
# the label directly used to be possible and silently produced a label the docs
# never mention, so an issue tagged claude-<codename> routed nowhere.
AGENT_CODENAME="${AGENT_CODENAME:-$(hostname -s | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')}"
case "$AGENT_CODENAME" in
  ""|-*|*-) die "AGENT_CODENAME must be lowercase letters, digits and hyphens, and must not start or end with one (got: '$AGENT_CODENAME')" ;;
  *[!a-z0-9-]*) die "AGENT_CODENAME may only contain lowercase letters, digits and hyphens (got: '$AGENT_CODENAME')" ;;
esac
AGENT_LABEL="claude-$AGENT_CODENAME"

DEFAULT_BRANCH="$(git -C "$CLONE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo main)"

cat > "$DIR/config.env" <<EOF
# claude-issue-agent config for $REPO
REPO="$REPO"
OWNER_LOGIN="$OWNER_LOGIN"
CLONE="$CLONE"
WORKTREE_ROOT="$DIR/worktrees"
DEFAULT_BRANCH="$DEFAULT_BRANCH"
BRANCH_PREFIX="claude/issue-"
POLL_INTERVAL="60"
BUSY_INTERVAL="10"
HEARTBEAT_INTERVAL="10"
# Space-separated GitHub logins allowed to drive this machine. Empty means
# anyone who can label an issue in this repo — safe only while it stays private.
ALLOWED_USERS="${ALLOWED_USERS:-}"
PERMISSION_MODE="$PERMISSION_MODE"
AGENT_LABEL="$AGENT_LABEL"
DEFAULT_MODEL="claude-opus-5"
DEFAULT_EFFORT="high"
EOF

mkdir -p "$DIR/worktrees"

# Sandbox: Bash commands may only write inside the worktree they run in, but
# the network stays open so the agent can install packages and call APIs.
cat > "$DIR/sandbox-settings.json" <<'SB'
{
  "sandbox": {
    "enabled": true,
    "network": { "allowedDomains": ["*"] },
    "filesystem": { "denyRead": ["~/.ssh", "~/.aws", "~/.gnupg"] }
  }
}
SB

# Only the routing label is created. Model labels are the user's choice: adding
# 25 of them to someone's repository fills a shared namespace their whole team
# sees, to express a preference most issues never use. `ctl.sh labels` creates
# the ones they actually want.
# The routing label is load-bearing: without it nothing ever reaches this
# machine, so a failure to create it must not pass silently.
if ! gh label list --repo "$REPO" --limit 200 --json name --jq '.[].name' \
     | grep -qx "$AGENT_LABEL"; then
  gh label create "$AGENT_LABEL" --repo "$REPO" --color 7C3AED \
    --description "Route this issue to $(hostname -s)" \
    || die "Could not create the routing label '$AGENT_LABEL' in $REPO.
Your token can read the repo but not write labels. Fix that, or create the
label by hand, then re-run setup."
fi

cat <<EOF

Setup done for $REPO

  config      $DIR/config.env
  local clone $CLONE
  worktrees   $DIR/worktrees
  logs        $DIR/logs

This machine answers to label:  $AGENT_LABEL

Put that label on an issue and this machine picks it up. Issues without it are
never touched, so another machine can watch the same repo under its own label.

Add a second label to pick the model, e.g. sonnet-5-low or fable-5-max.
No model label means the default: claude-opus-5 at high effort.

Only the routing label was created. To add model labels, name the ones you want:
  ctl.sh labels $REPO sonnet-5-low opus-5
or pass none to create all 25 combinations.

Permission mode: $PERMISSION_MODE
Allowed users:   ${ALLOWED_USERS:-anyone who can label an issue in this repo}
Sandbox: Bash commands can only write inside the issue's worktree. Network is
open. ~/.ssh, ~/.aws and ~/.gnupg are unreadable.

Next (unattended, restarts on crash and at login):
  $(dirname "${BASH_SOURCE[0]}")/ctl.sh install $REPO
EOF
