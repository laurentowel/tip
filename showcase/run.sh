#!/usr/bin/env bash
# Run the tip showcase.  Default: visible frame on the host
# compositor.  With --headless, wrap in a nested sway + wf-recorder
# pipeline so nothing shows on the user's desktop and an mp4 lands
# in recordings/.
#
# Under nix, prefer `nix run .#showcase` (visible) or `.#showcase-
# record-headless' (mp4).  This script is the portable equivalent.

set -eu

here="${TIP_SHOWCASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
repo="${TIP_REPO:-$(dirname "$here")}"

emacs_cmd="${EMACS:-emacs}"
mode="visible"
sleep_between=""

while [ $# -gt 0 ]; do
  case "$1" in
    --headless)       mode="headless"; shift;;
    --sleep|-s)       sleep_between="$2"; shift 2;;
    --sleep=*)        sleep_between="${1#--sleep=}"; shift;;
    --lang=*)         export TIP_SHOWCASE_LANG="${1#--lang=}"; shift;;
    --out=*)          export TIP_RECORD_OUT="${1#--out=}"; shift;;
    -h|--help)
      cat <<USAGE
Usage: run.sh [OPTIONS]
  --headless          Record without showing a frame (needs sway +
                      wf-recorder on PATH).
  --sleep N, -s N     Inter-step pause in seconds (visible mode only).
  --lang=en|zh        Showcase language (default en).
  --out=PATH          MP4 output path (headless mode).
  -h, --help          This help.

Env:
  TIP_REPO, TIP_SHOWCASE_DIR, TIP_RECORD_OUT, TIP_RECORD_DIR,
  TIP_SHOWCASE_LANG, TIP_SHOWCASE_THEME, TIP_FULLSCREEN, EMACS
USAGE
      exit 0;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2;;
  esac
done

if [ -n "$sleep_between" ]; then
  export TIP_SHOWCASE_PAUSE="$sleep_between"
fi

case "$mode" in
  visible)
    # --name sets emacs-pgtk's Wayland app_id to `tip-showcase', so
    # niri/sway window rules can target the showcase frame without
    # matching every other emacs you have open.
    exec "$emacs_cmd" --name tip-showcase -Q -l "$here/init.el"
    ;;
  headless)
    # Actually "nested" — niri has no true headless mode.  Runs a
    # nested niri on the host compositor (visible window, app_id
    # "niri").  Configure a host niri/sway window-rule to match it
    # if you want it floated.  Uses the host's system niri by
    # default for GPU/EGL access (nixpkgs niri wouldn't find
    # /run/opengl-driver on non-NixOS hosts).
    ts=$(date +%Y%m%d-%H%M%S)
    dir="${TIP_RECORD_DIR:-$here/recordings}"
    mkdir -p "$dir"
    out="${TIP_RECORD_OUT:-$dir/tip-showcase-nested-$ts.mp4}"
    export TIP_RECORD_OUT="$out"
    export TIP_FULLSCREEN=1

    niri_cmd="${NIRI:-niri}"

    conf=$(mktemp --suffix=.tip-niri.kdl)
    cat > "$conf" <<EOF
// Minimal nested niri config for the tip showcase.
input { keyboard { xkb { layout "us"; }; }; }
layout {
  border { off; }
  focus-ring { off; }
  gaps 0;
}
hotkey-overlay { skip-at-startup; }
spawn-at-startup "sh" "-c" "$emacs_cmd --name tip-showcase -Q -l $here/init.el; niri msg action quit --skip-confirmation"
EOF
    "$niri_cmd" -c "$conf" 2>/tmp/tip-niri.log || true
    rm -f "$conf"
    echo "wrote $out" >&2

    # Derive a sibling .gif.
    if command -v ffmpeg >/dev/null 2>&1 && [ -s "$out" ]; then
      gif="${out%.mp4}.gif"
      palette=$(mktemp --suffix=.png)
      ffmpeg -y -v error -i "$out" \
        -vf 'fps=12,scale=960:-1:flags=lanczos,palettegen' "$palette" && \
      ffmpeg -y -v error -i "$out" -i "$palette" \
        -filter_complex \
        'fps=12,scale=960:-1:flags=lanczos[x];[x][1:v]paletteuse' \
        "$gif" && echo "wrote $gif" >&2
      rm -f "$palette"
    fi
    ;;
esac
