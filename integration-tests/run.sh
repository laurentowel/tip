#!/usr/bin/env bash
# Orchestrator for TIP integration tests.  Starts one long-lived emacs
# daemon, loads every spec under specs/, runs all registered tests in
# sequence, prints the summary, stops the daemon.  Exit 0 iff all pass.
#
# Prefers the ambient `emacs` on PATH.  Under nix, use `nix run
# .#integration-tests` (which wraps this with a pinned emacs + typst
# tree-sitter grammar + tip-server on PATH).

set -eu

# --- flag parsing ---
sleep_between="${TIP_IT_SLEEP:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --sleep|-s)      sleep_between="$2"; shift 2;;
    --sleep=*)       sleep_between="${1#--sleep=}"; shift;;
    --headless)      export TIP_IT_HEADLESS=1; shift;;
    -h|--help)
      cat <<'USAGE'
Usage: run.sh [OPTIONS]
  --sleep N, -s N    Pause N seconds between consecutive tests so a
                     human watching the frame can see each result
                     settle before the next starts.  Default 0.
                     Env: TIP_IT_SLEEP.
  --headless         Don't pop a visible frame (CI mode).
                     Env: TIP_IT_HEADLESS=1.
  -h, --help         This message.
USAGE
      exit 0;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2;;
  esac
done
export TIP_IT_SLEEP="$sleep_between"

# TIP_IT_DIR: absolute path to the integration-tests/ directory.
# The nix app wrapper sets this so run.sh doesn't have to live inside
# the tree it drives.  Outside nix we self-locate.
HERE="${TIP_IT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO="$(dirname "$HERE")"
DAEMON="tip-it-$$"
INIT="$HERE/lib/daemon-init.el"

emacs_cmd="${EMACS:-emacs}"
emacsclient_cmd="${EMACSCLIENT:-emacsclient}"

cleanup() {
  "$emacsclient_cmd" -s "$DAEMON" -e '(kill-emacs 0)' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "tip integration-tests — starting daemon $DAEMON"
echo "  emacs=$emacs_cmd   sleep-between=${sleep_between}s   headless=${TIP_IT_HEADLESS:-0}"
# Keep daemon stderr visible so startup failures don't become silent
# "daemon never came up" timeouts.
"$emacs_cmd" --fg-daemon="$DAEMON" -l "$INIT" &
daemon_pid=$!

# Wait just enough for the daemon's socket to exist before opening the
# GUI frame.  Daemon-init itself may take longer; we re-check below.
for _ in $(seq 1 50); do
  if "$emacsclient_cmd" -s "$DAEMON" -e 't' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# Pop a visible frame the user can watch tests run inside.  -n = don't
# block waiting for the frame to close.  Overridable with TIP_IT_HEADLESS=1.
if [ "${TIP_IT_HEADLESS:-0}" != "1" ]; then
  "$emacsclient_cmd" -s "$DAEMON" --create-frame --no-wait >/dev/null 2>&1 || true
fi

# Wait for daemon to fully load daemon-init.el, not just socket ready.
# (tip-test-daemon-run is defined there; its presence marks "ready".)
echo "  waiting for daemon to finish init..."
for _ in $(seq 1 100); do
  if "$emacsclient_cmd" -s "$DAEMON" \
       -e '(fboundp (quote tip-test-daemon-run))' 2>/dev/null \
     | grep -q '^t$'; then
    echo "  daemon ready"
    break
  fi
  sleep 0.1
done
if ! "$emacsclient_cmd" -s "$DAEMON" \
     -e '(fboundp (quote tip-test-daemon-run))' 2>/dev/null \
   | grep -q '^t$'; then
  echo "FATAL: daemon init never finished" >&2
  kill "$daemon_pid" 2>/dev/null || true
  exit 2
fi

echo "  loading spec files..."
"$emacsclient_cmd" -s "$DAEMON" -e \
  '(progn (setq tip-test--tests nil)
          (tip-test-load-specs tip-test--specs-dir)
          (length tip-test--tests))' \
  | sed 's/^/    registered /'

echo "  running tests (one at a time, visible in frame)..."
echo
# Run once, stash results in a global var so we can both pretty-print
# the summary AND read the failure count without re-running anything.
"$emacsclient_cmd" -s "$DAEMON" \
  -e '(setq tip-test--last-run (tip-test-run-all))' >/dev/null

summary="$("$emacsclient_cmd" -s "$DAEMON" \
           -e '(tip-test-format-summary tip-test--last-run)')"
summary="${summary%\"}"
summary="${summary#\"}"
printf '%b\n' "$summary"

echo
failed="$("$emacsclient_cmd" -s "$DAEMON" \
          -e '(plist-get tip-test--last-run :failed)')"
if [ "$failed" = "0" ]; then
  echo "  RESULT: all tests passed"
  exit 0
else
  echo "  RESULT: $failed test(s) failed"
  exit 1
fi
