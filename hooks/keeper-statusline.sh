#!/usr/bin/env bash
# keeper-statusline.sh — the [KEEPER:NN%] badge.
#
# This runs on every statusline render, which is effectively every keystroke, so
# it only ever reads the cached state file: never the probe, never keeper.sh.
# The whole file is read in one pass with no subprocesses, because the earlier
# field-by-field version cost ~30 forks per render.
#
# The badge always renders something. An absent badge is indistinguishable from a
# statusline nobody wired, which is exactly the wrong signal in the failure mode
# where the guard has stopped working.
#
# Wire it after any other segments in ~/.claude/settings.json:
#   "statusLine": {"type":"command","command":"... ; printf ' '; bash \"$HOME/.claude/skills/keeper/hooks/keeper-statusline.sh\""}

HOME_DIR="${KEEPER_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
STATE="$HOME_DIR/.keeper-state"
CONFIG="$HOME_DIR/.keeper-config"
PROBE_ERR="$HOME_DIR/.keeper-probe-error"

GREEN=108; AMBER=173; RED=160; GREY=245

badge() { printf '\033[38;5;%sm[KEEPER%s]\033[0m' "$1" "$2"; }

# A symlinked state file could point at any file on disk and have its bytes
# re-rendered to the terminal on every keystroke, so it is refused rather than
# read — and the refusal is shown, not swallowed.
if [ -L "$STATE" ] || [ -L "$CONFIG" ]; then badge "$RED" ":!"; exit 0; fi

enabled=1
if [ -f "$CONFIG" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      enabled)   enabled="${v//[!01]/}" ;;
      threshold) threshold="${v//[!0-9]/}" ;;
    esac
  done < <(head -c 512 "$CONFIG" 2>/dev/null)
fi
: "${threshold:=95}"
case "$threshold" in ''|*[!0-9]*) threshold=95 ;; esac
[ -z "$enabled" ] && enabled=1

if [ "$enabled" != "1" ]; then badge "$GREY" ":OFF"; exit 0; fi

pct=""; blocked=0; reset_epoch=""; fetched=""; est=0
if [ -f "$STATE" ]; then
  # Values are filtered to the characters a badge can legitimately contain, so
  # escape sequences or OSC hyperlinks in a tampered file cannot reach the
  # terminal. Only these four fields are ever printed.
  while IFS='=' read -r k v; do
    case "$k" in
      pct)         pct="${v//[!0-9]/}" ;;
      blocked)     blocked="${v//[!01]/}" ;;
      reset_epoch) reset_epoch="${v//[!0-9]/}" ;;
      fetched_at)  fetched="${v//[!0-9]/}" ;;
      reset_est)   est="${v//[!01]/}" ;;
    esac
  done < <(head -c 512 "$STATE" 2>/dev/null)
fi
[ -z "$est" ] && est=0
[ "${#pct}" -gt 3 ] && pct=100
[ -n "$pct" ] && [ "$pct" -gt 100 ] && pct=100
[ -z "$blocked" ] && blocked=0

# No usable percentage is the failure mode that matters most, and it used to show
# up as nothing at all. `!` is reserved for exactly that — a guard with a known
# reason for having no reading — because a badge that cries wolf over a working
# guard trains you to ignore it.
if [ -z "$pct" ]; then
  if [ -f "$PROBE_ERR" ]; then badge "$RED" ":!"; else badge "$GREY" ":?"; fi
  exit 0
fi

now=$(date +%s)

if [ "$blocked" = "1" ] && [ -n "$reset_epoch" ] && [ "$reset_epoch" -gt "$now" ]; then
  left=$(( reset_epoch - now ))
  h=$((left/3600)); m=$(((left%3600)/60))
  if [ "$h" -gt 0 ]; then countdown="${h}h${m}m"; else countdown="${m}m"; fi
  badge "$RED" ":${pct}% BLOCKED $countdown"
  exit 0
fi
# Past its reset, a blocked flag is stale: only a tool call can clear it, so an
# idle session would otherwise sit on a red 0m countdown indefinitely.

# The colors track the configured threshold rather than fixed cuts, or they stop
# meaning "near the wall" the moment the threshold moves.
amber_at=$(( threshold - 25 ))
[ "$amber_at" -lt 1 ] && amber_at=1
if   [ "$pct" -ge "$threshold" ]; then color=$RED
elif [ "$pct" -ge "$amber_at" ];  then color=$AMBER
else color=$GREEN; fi

# A reading nobody refreshed is flagged, on a bound that tightens with usage:
# a flat 15 minutes was loosest exactly where the margin is thinnest.
suffix=""
if [ -n "$fetched" ] && [ "$fetched" -gt 0 ]; then
  limit=900
  [ "$pct" -ge 70 ] && limit=360
  [ "$pct" -ge 90 ] && limit=180
  [ $(( now - fetched )) -gt "$limit" ] && suffix="?"
fi
# The percentage is exact; only the reset time is guessed. `~` says that without
# implying the number above it cannot be trusted.
[ "$est" = "1" ] && suffix="$suffix~"

badge "$color" ":${pct}%${suffix}"
