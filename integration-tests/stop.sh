#!/usr/bin/env bash
# Gracefully stop every tip-it-* daemon currently running.
# Prefers `emacsclient -e (kill-emacs 0)` so in-flight cleanup (e.g.
# tip-server shutdown, temp-file delete) happens normally.  Falls
# back to SIGTERM → SIGKILL if the client can't talk to the socket.

set -eu

emacsclient_cmd="${EMACSCLIENT:-emacsclient}"
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
socket_dir="$runtime_dir/emacs"

if [ ! -d "$socket_dir" ]; then
  echo "no emacs socket dir at $socket_dir — nothing to stop"
  exit 0
fi

shopt -s nullglob
found=0
for sock in "$socket_dir"/tip-it-*; do
  name=$(basename "$sock")
  found=1
  echo "stopping $name..."
  if "$emacsclient_cmd" -s "$name" -e '(kill-emacs 0)' >/dev/null 2>&1; then
    echo "  graceful"
  else
    # Stale socket; find the PID the socket matches (if any) by walking
    # /proc for emacs processes with that --fg-daemon= arg.
    pid=$(pgrep -f "fg-daemon=$name" || true)
    if [ -n "$pid" ]; then
      echo "  client unreachable, SIGTERM $pid"
      kill "$pid" 2>/dev/null || true
      sleep 0.5
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$sock"
    echo "  cleaned"
  fi
done

if [ "$found" -eq 0 ]; then
  echo "no tip-it-* daemons running"
fi
