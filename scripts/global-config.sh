#!/usr/bin/env bash
# Local machine configuration. This file parses known keys and never sources config.
set -u

cfg_root="${AGENT_SKILLS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-skills}"
cfg_file="${AGENT_SKILL_CLAUDE_ISSUE_AGENT_CONFIG:-$cfg_root/claude-issue-agent/config.env}"
_cfg_home=""; _cfg_cli=""; _cfg_projects=""; _cfg_label=""; _cfg_branch=""
_cfg_model=""; _cfg_effort=""; _cfg_poll=""; _cfg_busy=""; _cfg_heartbeat=""
_cfg_models=""; _cfg_efforts=""

expand_home() { case "$1" in '~/'*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }
if [ -f "$cfg_file" ]; then
  while IFS='=' read -r key value; do
    case "$key" in ''|'#'*) continue ;; esac
    value=${value%$'\r'}
    case "$value" in '"'*'"'|"'"*"'") value=${value:1:${#value}-2} ;; esac
    case "$key" in
      CLAUDE_ISSUE_AGENT_HOME) _cfg_home=$value ;;
      CLAUDE_ISSUE_CLI) _cfg_cli=$value ;;
      CLAUDE_PROJECTS_DIR) _cfg_projects=$value ;;
      CLAUDE_ISSUE_LABEL_PREFIX) _cfg_label=$value ;;
      CLAUDE_ISSUE_BRANCH_PREFIX) _cfg_branch=$value ;;
      CLAUDE_ISSUE_DEFAULT_MODEL) _cfg_model=$value ;;
      CLAUDE_ISSUE_DEFAULT_EFFORT) _cfg_effort=$value ;;
      CLAUDE_ISSUE_POLL_INTERVAL) _cfg_poll=$value ;;
      CLAUDE_ISSUE_BUSY_INTERVAL) _cfg_busy=$value ;;
      CLAUDE_ISSUE_HEARTBEAT_INTERVAL) _cfg_heartbeat=$value ;;
      CLAUDE_ISSUE_KNOWN_MODELS) _cfg_models=$value ;;
      CLAUDE_ISSUE_VALID_EFFORTS) _cfg_efforts=$value ;;
    esac
  done < "$cfg_file"
fi

CLAUDE_ISSUE_AGENT_HOME="$(expand_home "${CLAUDE_ISSUE_AGENT_HOME:-${_cfg_home:-$HOME/.local/state/agent-skills/claude-issue-agent}}")"
CLAUDE_ISSUE_CLI="${CLAUDE_ISSUE_CLI:-${_cfg_cli:-claude}}"
CLAUDE_PROJECTS_DIR="$(expand_home "${CLAUDE_PROJECTS_DIR:-${_cfg_projects:-$HOME/.claude/projects}}")"
CLAUDE_ISSUE_LABEL_PREFIX="${CLAUDE_ISSUE_LABEL_PREFIX:-${_cfg_label:-claude}}"
CLAUDE_ISSUE_BRANCH_PREFIX="${CLAUDE_ISSUE_BRANCH_PREFIX:-${_cfg_branch:-claude/issue-}}"
CLAUDE_ISSUE_DEFAULT_MODEL="${CLAUDE_ISSUE_DEFAULT_MODEL:-${_cfg_model:-claude-opus-5}}"
CLAUDE_ISSUE_DEFAULT_EFFORT="${CLAUDE_ISSUE_DEFAULT_EFFORT:-${_cfg_effort:-high}}"
CLAUDE_ISSUE_POLL_INTERVAL="${CLAUDE_ISSUE_POLL_INTERVAL:-${_cfg_poll:-60}}"
CLAUDE_ISSUE_BUSY_INTERVAL="${CLAUDE_ISSUE_BUSY_INTERVAL:-${_cfg_busy:-10}}"
CLAUDE_ISSUE_HEARTBEAT_INTERVAL="${CLAUDE_ISSUE_HEARTBEAT_INTERVAL:-${_cfg_heartbeat:-10}}"
CLAUDE_ISSUE_KNOWN_MODELS="${CLAUDE_ISSUE_KNOWN_MODELS:-${_cfg_models:-fable-5-1 fable-5 opus-5 opus-4-6 sonnet-5 haiku-4-5}}"
CLAUDE_ISSUE_VALID_EFFORTS="${CLAUDE_ISSUE_VALID_EFFORTS:-${_cfg_efforts:-low medium high xhigh max}}"
