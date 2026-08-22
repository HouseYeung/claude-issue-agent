#!/usr/bin/env bash
# Start / stop / inspect the watcher for one repository.
# Usage: ctl.sh <start|stop|status|logs|install|uninstall> <owner/repo>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

CMD="${1:?usage: ctl.sh <start|stop|status|logs|labels|install|uninstall> <owner/repo> [args]}"
REPO="${2:?owner/repo}"
DIR="$(inst_dir "$REPO")"
PIDF="$DIR/poll.pid"
LABEL="com.claude.claude-issue-agent.$(slug "$REPO")"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UNIT="claude-issue-agent-$(slug "$REPO").service"
UNIT_DIR="$HOME/.config/systemd/user"

# launchd on macOS, systemd --user on Linux. Only install/uninstall differ in
# full; start/stop/status/logs drive plain processes and work on both.
case "$(uname -s)" in
  Darwin) SERVICE=launchd ;;
  *)      SERVICE=systemd ;;
esac

# systemctl --user needs the bus; a non-login shell (cron, wsl.exe -e) has no
# XDG_RUNTIME_DIR and would otherwise fail with "Failed to connect to bus".
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

# Is this repo's watcher registered with the service manager?
svc_installed() {
  case "$SERVICE" in
    launchd) [ -f "$PLIST" ] ;;
    systemd) [ -f "$UNIT_DIR/$UNIT" ] ;;
  esac
}

# Both managers restart the watcher on exit, so anything that kills it by pid
# has to take the service down first or it comes straight back.
svc_stop() {
  svc_installed || return 0
  case "$SERVICE" in
    launchd) launchctl unload "$PLIST" 2>/dev/null || true ;;
    systemd) systemctl --user stop "$UNIT" 2>/dev/null || true ;;
  esac
}

case "$CMD" in
  start)
    running && die "Already running (pid $(cat "$PIDF"))."
    # A stray watcher from an earlier run would race this one for the same
    # issues, so refuse to start while any is alive.
    if pgrep -f "poll.sh $REPO" >/dev/null 2>&1; then
      die "A watcher for $REPO is still alive: $(pgrep -f "poll.sh $REPO" | tr '\n' ' ')
Run: ctl.sh stop $REPO"
    fi
    mkdir -p "$DIR/logs"
    # Only clear a lock whose owner is gone.
    if [ -d "$DIR/poll.lock" ]; then
      lpid="$(cat "$DIR/poll.lock/pid" 2>/dev/null || echo '')"
      if [ -z "$lpid" ] || ! kill -0 "$lpid" 2>/dev/null; then
        rm -rf "$DIR/poll.lock"
      else
        die "Lock held by live pid $lpid. Run: ctl.sh stop $REPO"
      fi
    fi
    nohup "$HERE/poll.sh" "$REPO" >> "$DIR/logs/poll.log" 2>&1 &
    echo $! > "$PIDF"
    sleep 1
    running && echo "Started (pid $(cat "$PIDF")). Log: $DIR/logs/poll.log" \
            || { echo "Failed to start. Last log lines:"; tail -20 "$DIR/logs/poll.log"; exit 1; }
    ;;
  stop)
    # Before touching pids: a live service would restart everything killed below.
    if svc_installed; then svc_stop; echo "Service stopped (re-arm with: ctl.sh install $REPO)."; fi
    if running; then kill "$(cat "$PIDF")" 2>/dev/null && echo "Stopped pid $(cat "$PIDF")."; fi
    # Catch watchers this pid file lost track of.
    sleep 1
    if pgrep -f "poll.sh $REPO" >/dev/null 2>&1; then
      echo "Killing strays: $(pgrep -f "poll.sh $REPO" | tr '\n' ' ')"
      pkill -f "poll.sh $REPO" || true
      sleep 1
    fi
    pkill -9 -f "poll.sh $REPO" 2>/dev/null || true
    rm -f "$PIDF" "$DIR"/state/issue-*.runpid "$DIR"/state/issue-*.claudepid
    rm -rf "$DIR/poll.lock"
    echo "All watchers for $REPO stopped."
    ;;
  status)
    # A service-started watcher writes no pid file, so fall back to the lock,
    # which poll.sh writes for itself however it was launched.
    lockpid="$(cat "$DIR/poll.lock/pid" 2>/dev/null || echo '')"
    if running; then
      echo "RUNNING  pid $(cat "$PIDF")"
    elif [ -n "$lockpid" ] && kill -0 "$lockpid" 2>/dev/null; then
      echo "RUNNING  pid $lockpid"
    else
      echo "STOPPED"
    fi
    echo "repo      $REPO"
    echo "dir       $DIR"
    if ! svc_installed; then
      echo "service   not installed (ctl.sh start only, no restart on crash)"
    elif [ "$SERVICE" = systemd ]; then
      echo "service   systemd $UNIT  $(systemctl --user is-active "$UNIT" 2>/dev/null || true)/$(systemctl --user is-enabled "$UNIT" 2>/dev/null || true)"
    else
      echo "service   launchd $LABEL"
    fi
    echo "issues:"
    for f in "$DIR"/state/issue-*.json; do
      [ -e "$f" ] || { echo "  (none yet)"; break; }
      n="$(basename "$f" .json | sed 's/issue-//')"
      run=""
      rp="$DIR/state/issue-$n.runpid"
      if [ -f "$rp" ] && kill -0 "$(cat "$rp")" 2>/dev/null; then
        # Wall-clock age of the run's pid file, so a wedged turn is visible.
        started=$(stat -f %m "$rp" 2>/dev/null || stat -c %Y "$rp" 2>/dev/null || echo 0)
        run="  RUNNING $(( ($(date +%s) - started) / 60 ))m"
      fi
      echo "  #$n  model=$(jq -r '.model // "-"' "$f")/$(jq -r '.effort // "-"' "$f")$run"
    done
    ;;
  logs)
    tail -f "$DIR/logs/poll.log"
    ;;
  labels)
    # Model labels are opt-in: setup creates only the routing label, because a
    # repository's label list is shared with everyone working in it.
    shift 2
    wanted="$*"
    if [ -z "$wanted" ]; then
      for m in $KNOWN_MODELS; do
        wanted="$wanted $m"
        for e in $VALID_EFFORTS; do wanted="$wanted $m-$e"; done
      done
    fi
    made=0; skipped=0
    for l in $wanted; do
      if ! parse_model_label "$l" >/dev/null 2>&1; then
        echo "skipping '$l': not a known model label (models: $KNOWN_MODELS; efforts: $VALID_EFFORTS)"
        skipped=$((skipped + 1)); continue
      fi
      pair="$(parse_model_label "$l")"
      if gh label create "$l" --repo "$REPO" --color 388BFD \
           --description "Run on ${pair%|*} at ${pair#*|} effort" 2>/dev/null; then
        made=$((made + 1))
      else
        skipped=$((skipped + 1))
      fi
    done
    echo "created $made label(s) in $REPO, skipped $skipped (already present or unknown)."
    ;;
  install)
    mkdir -p "$DIR/logs"
    if [ "$SERVICE" = systemd ]; then
      mkdir -p "$UNIT_DIR"
      cat > "$UNIT_DIR/$UNIT" <<UNIT_FILE
[Unit]
Description=claude-issue-agent watcher for $REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $HERE/poll.sh $REPO
Restart=always
RestartSec=5
TimeoutStopSec=20
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
StandardOutput=append:$DIR/logs/poll.log
StandardError=append:$DIR/logs/poll.log

[Install]
WantedBy=default.target
UNIT_FILE
      systemctl --user daemon-reload
      systemctl --user enable --now "$UNIT"
      # Without lingering the user manager exits with the last login session and
      # takes the watcher with it — fatal for something meant to run unattended.
      loginctl enable-linger "$(id -un)" 2>/dev/null \
        || echo "WARNING: lingering not enabled. Run: sudo loginctl enable-linger $(id -un)"
      echo "Installed as a systemd user unit ($UNIT). It starts at boot and restarts on crash."
      echo "Log: $DIR/logs/poll.log"
      exit 0
    fi
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$HERE/poll.sh</string><string>$REPO</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/logs/poll.log</string>
  <key>StandardErrorPath</key><string>$DIR/logs/poll.log</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin</string></dict>
</dict></plist>
PL
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "Installed as a launchd job ($LABEL). It starts at login and restarts on crash."
    echo "Log: $DIR/logs/poll.log"
    ;;
  uninstall)
    if [ "$SERVICE" = systemd ]; then
      systemctl --user disable --now "$UNIT" 2>/dev/null || true
      rm -f "$UNIT_DIR/$UNIT"
      systemctl --user daemon-reload
      echo "Removed $UNIT."
    else
      launchctl unload "$PLIST" 2>/dev/null || true
      rm -f "$PLIST"
      echo "Removed $LABEL."
    fi
    ;;
  *) die "Unknown command: $CMD" ;;
esac
