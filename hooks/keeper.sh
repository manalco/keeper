#!/usr/bin/env bash
# keeper.sh — guards the account's 5-hour session window.
#
# Why this exists: hitting the window limit mid-task loses work. Keeper watches
# the percentage and stops all tool use before the wall, then releases itself
# when the window rolls over.
#
# The percentage comes from `claude -p "/usage"`, which the CLI answers locally
# without any API call — so measuring costs zero tokens. It does take ~12s of
# wall clock, which is why the probe always runs detached and every hook here
# decides from cache. A hook that blocked on the probe would tax every tool call.
#
# Releasing the gate is not the same as resuming the work. The turn that hit the
# pause has already ended by the time the window rolls over, and nothing re-invokes
# the model, so the job used to sit there until a human noticed and typed. The Stop
# hook closes that gap: it holds the paused turn open across the rollover and then
# tells the model to carry on. Waiting costs no tokens — it is a sleeping shell.
#
# Two failure directions matter, and they are not symmetric. Failing open (never
# blocking) wastes the budget this exists to protect. Failing closed (blocking
# forever) is worse: while the gate denies, the very command that would lift it
# is denied too, so the user has to escape to an external terminal. Every
# ambiguous state below therefore resolves toward "allow, and say so loudly".
#
# Subcommands:
#   check          PreToolUse hook — allow silently, or deny while blocked
#   stop           Stop hook — hold the paused turn open until the window resets
#   session-start  SessionStart hook — short context block + opportunistic refresh
#   probe          fetch usage, update state (normally spawned detached)
#   status         human-readable state, for the /keeper skill
#   threshold N | on | off    configuration
#   ttl N          refresh interval for percentage N (exposed for the self-check)

set -uo pipefail

# System utilities first. A venv, direnv, or node_modules/.bin shim ahead of
# /usr/bin could otherwise replace the parser or the comparison tools this guard
# trusts. `claude` and `python3` still resolve from the inherited tail.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

KEEPER_HOME="${KEEPER_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
STATE="$KEEPER_HOME/.keeper-state"
CONFIG="$KEEPER_HOME/.keeper-config"
LOCK="$KEEPER_HOME/.keeper-probe.lock"
TIMER="$KEEPER_HOME/.keeper-timer.pid"
LASTCHECK="$KEEPER_HOME/.keeper-lastcheck"
PROBE_ERR="$KEEPER_HOME/.keeper-probe-error"
PROBE_ATTEMPT="$KEEPER_HOME/.keeper-probe-attempt"
PROBE_CWD="$KEEPER_HOME/.keeper-probe"
RESUMED="$KEEPER_HOME/.keeper-resumed"
HOLD="$KEEPER_HOME/.keeper-hold"
# Work stopped for the pause and has not moved since. The gate writes it on every
# denial and clears it the moment a tool runs again, which makes it the answer to
# the one question the Stop hook could not previously ask: is there anything left
# to restart? Without it, a pause that lifted before the turn ended took the
# restart with it — nothing was holding the turn, and nothing re-invokes a model.
PENDING="$KEEPER_HOME/.keeper-pending"
DEFAULT_THRESHOLD=95
WINDOW_SECONDS=18000
# How long a record of interrupted work is worth acting on. The gap it has to
# cover is the one between a tool being denied and that turn ending — the model
# writing one line and stopping, so seconds. Holding it open for a whole window
# instead would let any denial anywhere in the account restart the next turn to
# end in any session, which is a restart with no interrupted work behind it.
STRANDED_SECONDS=120
# How long to wait after the clock says the window turned over, before reading it
# again and putting the model back to work. The rollover happens on the account's
# clock, not this one, and for a short while after it `/usage` still reports the
# window that just ended — its percentage as much as its label. Answering the
# instant the clock struck therefore restarted the work against the old reading:
# the probe the release forces wrote the ending window's 96% straight back, and
# the next tool call was denied on the spot, a second after the model had been
# told to carry on. A minute is enough for the account to agree that the window
# moved. The seam is for the self-check, which cannot afford to wait it out.
RESUME_GRACE="${KEEPER_RESUME_GRACE:-60}"
RESUME_GRACE_MAX="${KEEPER_RESUME_GRACE_MAX:-300}"
# Filtered like every other number that arrives from outside. A non-numeric value
# made sleep fail on the spot, which collapsed the grace to nothing and put the
# stale-reading bug back without a word — the worst way for a guard to break.
# Capped because this is the one wait the loop cannot re-examine in the middle of.
case "$RESUME_GRACE_MAX" in ''|*[!0-9]*) RESUME_GRACE_MAX=300 ;; esac
case "$RESUME_GRACE" in ''|*[!0-9]*) RESUME_GRACE=60 ;; esac
[ "$RESUME_GRACE" -gt "$RESUME_GRACE_MAX" ] && RESUME_GRACE="$RESUME_GRACE_MAX"

# The denial is the only instruction the model gets, and everything after the
# numbers is what decides whether the work restarts. It says end the turn,
# because the restart is delivered to a turn that has ended and there is nothing
# Keeper can do for one that keeps talking. It says the user need not answer,
# because asking them turns an automatic restart into a job waiting on a human.
# It asks for "how long" and not "when", because the reset time is sometimes
# unreadable and the duration never is — ordering a model to state a time it was
# not given is ordering it to invent one. And it is written once, so the two
# denials cannot drift apart, which they already had.
STOP_INSTRUCTIONS="Stop now: no retries, no other tools, no working around this in prose. Say in one line that Keeper paused the session and for how long. End the turn there. Keeper resumes this work by itself once the window rolls over, and the restart arrives on its own as KEEPER RESUME, carrying on from exactly here. The user does not need to reply or re-ask for that to happen, so do not ask them to."

mkdir -p "$KEEPER_HOME" 2>/dev/null

# A symlink at any of these paths would let a planted link capture a write and
# truncate or overwrite the target — `>` follows symlinks. Refusing to touch
# them is right, but refusing *silently* left the operator with no diagnostic,
# so the refusal is recorded and every human-facing subcommand reports it.
REFUSED=""
for f in "$STATE" "$CONFIG" "$LASTCHECK" "$TIMER" "$RESUMED"; do
  if [ -L "$f" ]; then REFUSED="$f"; break; fi
done

# The record gets the same refusal as everything else Keeper writes, but locally:
# adding it to the list above would let a link planted here switch the whole guard
# off, and a planted link should cost the restart, not the protection. Removing is
# always safe — rm takes the link, never what it points at.
pending_ok() { [ -z "$REFUSED" ] && [ ! -L "$PENDING" ]; }

# The record is one file for the whole account, so on its own it says a denial
# happened, not whose. The project the hooks were called for narrows it: a session
# in another checkout no longer answers for work it never interrupted. It is not
# a session id — the hooks deliberately never read stdin, where that would be —
# so two sessions in one project still share a record, which is why age and an
# atomic claim carry the rest of the weight.
pending_tag() { local t="${CLAUDE_PROJECT_DIR:-}"; printf '%s' "${t//[!a-zA-Z0-9]/-}"; }

# Written the way everything else here is written: mktemp then mv, which replaces
# a link rather than following one. Plain touch left a race — the check above says
# the path is not a link, and a link planted before the write still gets followed,
# stamping whatever it points at.
mark_pending() { pending_ok && pending_tag | atomic_write "$PENDING"; }

# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------
S_pct=""; S_reset=""; S_fetched=""; S_label=""; S_blocked=""; S_est=""

# One pass, no subprocesses: this runs on every tool call and every render.
# Fields are filtered here rather than at the write site because the file is the
# trust boundary, not the writer — anything on disk may have been tampered with,
# truncated mid-write, or produced by an older version.
load_state() {
  [ -n "$REFUSED" ] && return 1
  [ -f "$STATE" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      pct)         S_pct="${v//[!0-9]/}" ;;
      reset_epoch) S_reset="${v//[!0-9]/}" ;;
      fetched_at)  S_fetched="${v//[!0-9]/}" ;;
      blocked)     S_blocked="${v//[!01]/}" ;;
      reset_est)   S_est="${v//[!01]/}" ;;
      # Only what a clock label can legitimately contain, so nothing from this
      # file can inject JSON, shell, terminal escapes, or instructions to the
      # model — reset_human reaches the deny reason and the session block, both
      # of which are read as context.
      reset_human) S_label="${v//[!0-9:apm]/}" ;;
    esac
  done < "$STATE"
  # All-digit garbage passes a numeric filter but overflows the comparison, and
  # bash treats the resulting error as false — which used to mean "no block" at
  # full usage. Clamping keeps the comparison meaningful.
  [ "${#S_pct}" -gt 3 ] && S_pct=100
  [ -n "$S_pct" ] && [ "$S_pct" -gt 100 ] && S_pct=100
  [ "${#S_reset}" -gt 11 ] && S_reset=""
  [ "${#S_fetched}" -gt 11 ] && S_fetched=""
  S_label="${S_label:0:8}"
  [ -z "$S_blocked" ] && S_blocked=0
  return 0
}

threshold() {
  local v=""
  if [ -z "$REFUSED" ] && [ -f "$CONFIG" ]; then
    # Capped like every other read: an oversized file would otherwise be scanned
    # in full on paths that run per keystroke.
    v=$(head -c 512 "$CONFIG" 2>/dev/null | grep -E '^threshold=' | head -n1 | cut -d= -f2 | tr -cd '0-9')
  fi
  case "$v" in ''|*[!0-9]*) printf '%s' "$DEFAULT_THRESHOLD" ;; *) printf '%s' "$v" ;; esac
}
enabled() {
  if [ -n "$REFUSED" ] || [ ! -f "$CONFIG" ]; then printf '1'; return; fi
  local v
  v=$(head -c 512 "$CONFIG" 2>/dev/null | grep -E '^enabled=' | head -n1 | cut -d= -f2 | tr -cd '01')
  printf '%s' "${v:-1}"
}

# mktemp, not "$FILE.$$": the pid is a small guessable integer, so an attacker
# could pre-plant symlinks named after a range of pids and have the next write
# follow one — overwriting any file the user owns, and leaving the state file as
# a symlink, which the refusal above then turns into a permanent silent bypass.
atomic_write() { # path  (content on stdin)
  local path="$1" tmp
  tmp=$(mktemp "$path.XXXXXX") || return 1
  cat > "$tmp" && mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

write_config() { printf 'threshold=%s\nenabled=%s\n' "$1" "$2" | atomic_write "$CONFIG"; }

mtime() { # modification time in epoch seconds, 0 when unobtainable
  # GNU form first, then BSD. Chaining them the other way looked equivalent but
  # was not: GNU stat reads `-f %m` as a *filename*, prints a multi-line
  # filesystem report to stdout, and exits 1 — so the fallback ran too and the
  # caller got the report and the number concatenated, breaking every arithmetic
  # comparison on Linux. The numeric guard is what makes the order safe.
  local v
  v=$(stat -c %Y "$1" 2>/dev/null) || v=$(stat -f %m "$1" 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

# Refresh cadence. Far from the limit the number barely matters, so polling is
# lazy; close to it a stale reading is what lets usage blow past the wall. An
# unknown percentage is treated as close, because blind is not safe.
ttl_for() {
  local p="${1:-}"
  if   [ -z "$p" ];        then printf '90'
  elif [ "$p" -ge 90 ];    then printf '90'
  elif [ "$p" -ge 70 ];    then printf '180'
  else printf '600'; fi
}

human_left() { # seconds -> "2h14m" / "9m" / "<1m"
  local s="${1:-0}"
  [ "$s" -lt 0 ] && s=0
  local h=$((s/3600)) m=$(((s%3600)/60))
  # Truncating minutes printed "blocked for 0m" for the last 59 seconds of a
  # pause, which reads as a contradiction and was taken for one: a pause with
  # nothing left to wait for looks exactly like a pause that has gone stale.
  if   [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '<1m'; fi
}

write_state() { # pct reset_epoch reset_human blocked reset_est
  printf 'pct=%s\nreset_epoch=%s\nfetched_at=%s\nreset_human=%s\nblocked=%s\nreset_est=%s\n' \
    "$1" "$2" "$(date +%s)" "$3" "$4" "${5:-0}" | atomic_write "$STATE"
}

# sed replacing a line that is not there succeeded while persisting nothing, so a
# state file missing `blocked=` never recorded the pause — which made the release
# path, reachable only while blocked=1, dead code. Append when absent.
set_field() { # key value
  [ -n "$REFUSED" ] && return 0
  [ -f "$STATE" ] || return 0
  local k="$1" v="$2" out="" line found=0
  while IFS= read -r line; do
    case "$line" in
      "$k="*) out="$out$k=$v"$'\n'; found=1 ;;
      *)      out="$out$line"$'\n' ;;
    esac
  done < "$STATE"
  [ "$found" -eq 0 ] && out="$out$k=$v"$'\n'
  printf '%s' "$out" | atomic_write "$STATE"
}

notify() {
  local msg="${1//\"/}"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"Keeper\"" >/dev/null 2>&1 &
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "Keeper" "$msg" >/dev/null 2>&1 &
  fi
}

# ---------------------------------------------------------------------------
# probe
# ---------------------------------------------------------------------------
# Every failure used to be a bare `return 0` that wrote nothing, so a broken
# probe presented as a healthy quiet guard: no state, no badge, `status` saying
# the reassuring "no reading yet", and the gate allowing everything for the rest
# of the session. Recording the reason is what makes the failure visible, and it
# doubles as the backoff timestamp — without it, a permanently failing probe
# respawned `claude` on every single tool call.
probe_fail() {
  printf '%s\n' "$1" | atomic_write "$PROBE_ERR" 2>/dev/null
  date +%s | atomic_write "$PROBE_ATTEMPT" 2>/dev/null
  return 0
}

do_probe() {
  [ -n "$REFUSED" ] && return 0
  # mkdir is atomic, so it doubles as the lock. A lock older than 3 minutes is a
  # crashed probe, not a running one — the probe itself takes ~12s. The stale
  # lock is claimed by rename so two racers cannot both decide to clear it and
  # then both proceed.
  if ! mkdir "$LOCK" 2>/dev/null; then
    local age now
    now=$(date +%s)
    age=$(( now - $(mtime "$LOCK") ))
    [ "$age" -lt 180 ] && return 0
    mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null || return 0
    rm -rf "$LOCK.stale.$$" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || return 0
  fi
  trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

  date +%s | atomic_write "$PROBE_ATTEMPT" 2>/dev/null

  local raw=""
  if [ -n "${KEEPER_PROBE_FIXTURE:-}" ]; then
    raw=$(cat "$KEEPER_PROBE_FIXTURE" 2>/dev/null) || true
    [ -n "$raw" ] || { probe_fail "fixture unreadable"; return 0; }
  else
    command -v claude >/dev/null 2>&1 || { probe_fail "claude CLI not on PATH"; return 0; }
    # `timeout` is GNU coreutils and is NOT on a stock macOS, so it cannot be
    # required: without this guard the probe died with "command not found",
    # wrote nothing, and the guard quietly stopped guarding on any Mac without
    # Homebrew coreutils.
    local to=""
    command -v timeout >/dev/null 2>&1 && to="timeout 90"
    # Running from a dedicated directory keeps the throwaway transcript this
    # spawn creates in its own project folder, so cleanup can delete that exact
    # folder instead of guessing which file beside real transcripts is junk.
    # --strict-mcp-config with no servers cuts startup from ~40s to ~12s, and
    # </dev/null matters: without it the CLI waits forever on stdin.
    mkdir -p "$PROBE_CWD" 2>/dev/null
    raw=$(cd "$PROBE_CWD" && $to claude -p "/usage" \
            --strict-mcp-config --mcp-config '{"mcpServers":{}}' </dev/null 2>/dev/null)
    cleanup_transcript
    [ -n "$raw" ] || { probe_fail "probe returned nothing"; return 0; }
  fi

  # Scanned in-shell rather than piped into grep: an early-exiting reader closes
  # the pipe while the writer is still going, and the resulting EPIPE noise would
  # land on the hook's stderr.
  local line="" l
  while IFS= read -r l; do
    case "$l" in "Current session:"*) line="$l"; break ;; esac
  done <<< "$raw"
  [ -n "$line" ] || { probe_fail "no 'Current session:' line in /usage output"; return 0; }

  local pct
  pct=$(printf '%s' "$line" | sed -n 's/^Current session: *\([0-9]\{1,3\}\)%.*/\1/p')
  case "$pct" in ''|*[!0-9]*) probe_fail "could not read percentage"; return 0 ;; esac
  [ "$pct" -gt 100 ] && pct=100

  # Date math is the one part worth handing to python: the reset clause carries
  # its own timezone, and getting it wrong either blocks forever or never.
  local parsed
  parsed=$(python3 -c '
import re, sys
from datetime import datetime, timedelta
try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

line = sys.stdin.read()
m = re.search(r"resets\s+(?:(\w{3})\s+(\d{1,2})\s+at\s+)?(\d{1,2}):(\d{2})\s*([ap]m)?(?:\s*\(([^)]+)\))?",
              line, re.I)
if not m:
    sys.exit(1)
mon, day, hh, mm, ampm, tzname = m.groups()
hh, mm = int(hh), int(mm)
if ampm:
    # Case-insensitive: "3:50PM" once parsed as 03:50 and put the reset a year
    # out, which meant a pause that could never release.
    hh = hh % 12 + (12 if ampm.lower() == "pm" else 0)

tz = None
if tzname and ZoneInfo:
    try:
        tz = ZoneInfo(tzname)
    except Exception:
        tz = None
now = datetime.now(tz)

months = {m: i for i, m in enumerate(
    ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"], 1)}
target = None
if mon and mon.capitalize() in months:
    try:
        target = now.replace(month=months[mon.capitalize()], day=int(day),
                             hour=hh, minute=mm, second=0, microsecond=0)
    except ValueError:
        # An impossible date (Feb 30, day 31 of a 30-day month) must not cost us
        # a percentage that parsed perfectly well.
        target = None
if target is None:
    target = now.replace(hour=hh, minute=mm, second=0, microsecond=0)

# A label in the past is the normal reading in the seconds after a rollover: for
# a few moments /usage still names the window that just ended. The window is 5h
# long, so the next reset is that label plus 5h — treating it as unreadable
# instead raised a scary badge on every single rollover. Stepping rather than
# jumping also covers a label stale by more than one window.
steps = 0
while target <= now and steps < 4:
    target += timedelta(hours=5)
    steps += 1
if target <= now:
    sys.exit(1)

label = f"{(hh % 12) or 12}:{mm:02d}" + ("pm" if hh >= 12 else "am")
print(int(target.timestamp()), label)
' <<< "$line" 2>/dev/null)

  local epoch label est=0
  epoch=$(printf '%s' "$parsed" | cut -d' ' -f1 | tr -cd '0-9')
  label=$(printf '%s' "$parsed" | cut -d' ' -f2 | tr -cd '0-9:apm')
  local now; now=$(date +%s)

  # A label we cannot read must not throw away a percentage we can. Losing the
  # reading meant one upstream rewording of the reset clause would disable the
  # guard at exactly the moment it matters. Guessing conservatively still lets
  # the threshold trip; the estimate is marked so nothing presents it as read.
  # The label carries only minutes, and a reading taken moments after a rollover
  # legitimately sits a whole window out, so the ceiling needs slack — without it
  # a perfectly good reset time was rejected as nonsense.
  if [ -z "$epoch" ] || [ "$epoch" -le "$now" ] || [ $((epoch - now)) -gt $((WINDOW_SECONDS + 300)) ]; then
    # A whole window, not fifteen minutes. The number is a guess either way, and
    # the only honest thing a guess can do here is bound the wait: no window
    # outlasts its own length, so this cannot pause anything forever, and it
    # cannot end a pause early either. Fifteen minutes did exactly that — it
    # handed the tools back with the account still over the limit, and until then
    # it was counted down at the user as if somebody had measured it.
    epoch=$((now + WINDOW_SECONDS))
    label=""
    est=1
  fi
  # The reading itself succeeded, so any earlier failure is over. An estimated
  # reset is recorded in the state as reset_est, not as a probe error: the
  # percentage — the number the whole guard turns on — is exact either way, and
  # flagging it as a failure raised an alarming badge over a working guard.
  rm -f "$PROBE_ERR" 2>/dev/null

  load_state || true
  write_state "$pct" "$epoch" "$label" "${S_blocked:-0}" "$est"
}

# The old glob was an unanchored `rm -rf` over ~/.claude/projects: it would also
# match a real project whose path ends in "keeper-probe". Only the exact encoded
# name this probe creates is ours to delete.
cleanup_transcript() {
  local base enc cfg
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  enc="${PROBE_CWD//\//-}"
  for base in "$enc" "${enc//./-}"; do
    [ -d "$cfg/projects/$base" ] && rm -rf "$cfg/projects/$base" 2>/dev/null
  done
}

# Spawn the probe detached when the cache is older than its cadence allows, so
# no hook ever waits on it.
maybe_refresh() {
  [ -n "$REFUSED" ] && return 0
  # Test seam: the self-check must never spawn the real CLI, or its cases race a
  # detached probe writing genuine readings over their fixtures.
  [ -n "${KEEPER_NO_REFRESH:-}" ] && return 0
  local now age ttl
  now=$(date +%s)
  # Back off after a failure. Only success used to advance the timestamp this
  # compares, so a permanently broken probe started a real `claude` process on
  # every tool call for the rest of the session.
  if [ -f "$PROBE_ERR" ] && [ -f "$PROBE_ATTEMPT" ]; then
    [ $(( now - $(mtime "$PROBE_ATTEMPT") )) -lt 300 ] && return 0
  fi
  ttl=$(ttl_for "$S_pct")
  if [ -f "$STATE" ] && [ -n "$S_fetched" ]; then
    age=$(( now - S_fetched ))
    [ "$age" -lt "$ttl" ] && return 0
  fi
  # nohup, not setsid: setsid ships with util-linux and is absent on macOS, and
  # wrapping it in a backgrounded subshell hid the failure entirely. `bash "$0"`
  # rather than "$0" so a lost exec bit cannot silently end every refresh.
  nohup bash "$0" probe >/dev/null 2>&1 </dev/null &
}

# The timer is what makes the pause unattended: it announces the rollover so a
# stopped session needs nobody watching the clock.
arm_timer() {
  local left="${1:-0}"
  # A non-positive delay made `sleep` fail instantly; the ;-chained commands then
  # fired a "window reset" notification within a second while the gate kept
  # denying, and recorded a dead pid so the next call did it all again.
  [ "$left" -lt 1 ] && return 0
  local want="$2"
  if [ -f "$TIMER" ]; then
    local pid epoch
    read -r pid epoch < "$TIMER" 2>/dev/null || true
    pid="${pid//[!0-9]/}"; epoch="${epoch//[!0-9]/}"
    # A surviving pid file after a reboot can name an unrelated process, so the
    # recorded target is checked too, not just liveness.
    if [ -n "$pid" ] && [ "$epoch" = "$want" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
    disarm_timer
  fi
  # Data passed as arguments, never spliced into the source text: a single quote
  # in KEEPER_HOME or CLAUDE_CONFIG_DIR otherwise closed the quoting and the rest
  # of the path became code in a detached process that outlives the session.
  nohup sh -c 'sleep "$1"; if command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"Session window reset — Keeper released the pause.\" with title \"Keeper\"" >/dev/null 2>&1
    elif command -v notify-send >/dev/null 2>&1; then
      notify-send "Keeper" "Session window reset — Keeper released the pause." >/dev/null 2>&1
    fi; rm -f "$2"' keeper-timer "$left" "$TIMER" >/dev/null 2>&1 </dev/null &
  printf '%s %s\n' "$!" "$want" > "$TIMER" 2>/dev/null
}

disarm_timer() {
  [ -f "$TIMER" ] || return 0
  local pid
  read -r pid _ < "$TIMER" 2>/dev/null || true
  pid="${pid//[!0-9]/}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
  rm -f "$TIMER" 2>/dev/null
}

# Only digits and a filtered clock label ever reach this, so the JSON cannot be
# reshaped from disk. An unescaped label could previously close the object early
# and append "permissionDecision":"allow", turning the deny into an allow on
# last-key-wins parsers — and inject text into the model's context besides.
deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
}

# How long the pause has left, or an admission that nobody knows. A guessed reset
# time reported as a duration is worse than no duration at all: it reads as a
# measurement, and a pause with most of a window still to run announced fourteen
# minutes, which is what sent everyone looking for a stale cache.
blocked_for() {
  if [ "${S_est:-0}" = "1" ]; then
    printf 'until the window clears; its reset time could not be read, so there is no countdown to give'
  else
    printf 'for %s%s' "$(human_left "${1:-0}")" "$(until_phrase)"
  fi
}

until_phrase() { # "until 3:50pm" when the label is trustworthy, else silence
  if [ -n "$S_label" ] && [ "${S_est:-0}" != "1" ]; then printf ', until %s' "$S_label"; fi
}

# Is the pause over according to the reading rather than the clock? A percentage
# only falls back under the threshold once the window turned over, so this is the
# window itself saying so — and it is the only signal available when the rollover
# lands earlier than the reset time that was recorded when the pause began.
#
# The gate and the held-open turn both have to ask it. They used to ask different
# questions of the same file: the gate released on the clock, the turn waited on
# the clock, and a probe that had already read the new window sat in the state
# contradicting both. That disagreement is what denied every tool "at 0% (limit
# 95%)" while the turn it was supposed to restart slept on.
#
# The threshold is read live, not captured at probe time, so a threshold raised
# from another terminal is honoured here too, and the answer holds even when the
# probe is dead.
# The release that breaks a deadlock writes a zero nobody measured, and marks it
# by zeroing the timestamp beside it. Anything deciding on the percentage has to
# refuse that one, or the fabrication meant to unstick a corrupt reset time reads
# as an empty window and lets the work back out against a full one.
reading_cleared() {
  [ -n "$S_fetched" ] && [ "$S_fetched" -gt 0 ] &&
  [ -n "$S_pct" ] && [ "$S_pct" -lt "$(threshold)" ]
}

# Lifting a pause. Released on the clock, the cached reading belongs to the window
# that just ended, so it has to go with it or the very next tool call re-blocks;
# fetched_at is zeroed rather than inventing a percentage, which forces an
# immediate fresh probe.
#
# Released on the reading, the opposite holds: that percentage is already the new
# window's and is true. Zeroing it there would put a 0% on the statusline and in
# `status` for an account nowhere near it — a lie that outlives the next probe if
# the probe is broken.
release() { # [keep]  — keep: the cached reading is the new window's, not the old
  set_field blocked 0
  if [ "${1:-}" != "keep" ]; then
    set_field pct 0
    set_field fetched_at 0
    S_pct=0; S_fetched=0
  fi
  disarm_timer
  S_blocked=0
}

# The restart, written in one place because two paths reach it: the turn held open
# across the rollover, and the turn that ended after the pause had already lifted.
# Marking the restart is what stops it firing twice, and the record is spent here
# because the work it stood for is moving again.
#
# Static text and nothing from disk, so the state file cannot reshape this JSON or
# slip instructions into the turn it restarts.
resume_answer() {
  touch "$RESUMED" 2>/dev/null
  rm -f "$PENDING" 2>/dev/null
  printf '{"decision":"block","reason":"KEEPER RESUME — the pause is lifted and tools work again. Pick the interrupted work back up exactly where the pause stopped you and finish it. Do not wait for the user to ask again, and do not re-summarise what happened; just carry on, saying in one line that the pause lifted. If nothing in this session was interrupted, say that in one line and stop."}\n'
  exit 0
}

# ---------------------------------------------------------------------------
# stop — hold the paused turn open across the rollover
# ---------------------------------------------------------------------------
do_stop() {
  [ -n "$REFUSED" ] && exit 0
  [ "$(enabled)" = "1" ] || exit 0
  load_state || exit 0
  # Only a turn that actually hit the pause is held; any other stop is none of
  # Keeper's business and must cost nothing.
  #
  # Except one: the pause may already have lifted while this turn was ending —
  # released by another session, by a raised threshold, or by the gate itself on
  # a reading that came back under the limit. Then there is no pause to hold, the
  # wait below never starts, and nothing re-invokes the model. That is the shape
  # the failure takes from the outside: the job simply stops and waits for the
  # user to type, having already announced that it would continue on its own.
  # The record answers it — the work was interrupted and has not moved since.
  if [ "$S_blocked" != "1" ]; then
    pending_ok || exit 0
    [ -f "$PENDING" ] || exit 0
    # Everything the wait checks before it puts a model back to work, this has to
    # check too. A corrupt reset time makes the gate take its escape-hatch
    # release, which fabricates pct=0 to break the deadlock — the account can be
    # at 99% behind it. Restarting on that fabrication drives the work straight
    # into the wall Keeper exists to hold it back from. A real reading has a real
    # fetched_at; the fabricated one is zeroed precisely so nothing trusts it.
    [ -n "$S_fetched" ] && [ "$S_fetched" -gt 0 ] || exit 0
    reading_cleared || exit 0
    # Read back from the same file the gate wrote, and filtered on the way in:
    # the record is on disk, so it is not trusted to be what Keeper last wrote.
    local tag_now tag_rec
    tag_now=$(pending_tag)
    tag_rec=$(head -c 200 "$PENDING" 2>/dev/null | tr -cd 'a-zA-Z0-9-')
    [ "$tag_rec" = "$tag_now" ] || exit 0
    local now_p; now_p=$(date +%s)
    # The record is one file for the whole account, like the pause itself, so it
    # says a denial happened — not which turn it happened to. Age is what ties it
    # back: the turn that was denied ends moments later, while a turn that ends
    # long afterwards is some other session going about its business, and
    # restarting that one hands a user work they never interrupted.
    if [ $(( now_p - $(mtime "$PENDING") )) -ge "$STRANDED_SECONDS" ]; then
      rm -f "$PENDING" 2>/dev/null; exit 0
    fi
    # The same loop guard the rollover path uses: a restart that just fired must
    # not fire again on the stop it caused.
    [ $(( now_p - $(mtime "$RESUMED") )) -lt 60 ] && exit 0
    # One record, one restart. Sessions parked behind a single pause all end their
    # turns the moment it lifts, and each would find this record: N turns spending
    # the window that was just protected. Testing then deleting is not a claim —
    # both would pass the test. mv is: it either moves the file or it does not, so
    # exactly one caller can win it, the way the probe and the hold both claim
    # with mkdir. It takes the record rather than the hold lock, so a session
    # genuinely waiting out a pause is left alone.
    mv "$PENDING" "$PENDING.claimed.$$" 2>/dev/null || exit 0
    rm -f "$PENDING.claimed.$$" 2>/dev/null
    notify "Keeper released the pause — resuming the interrupted work."
    resume_answer
  fi
  # An estimated reset is a 15-minute placeholder, not a reading. Waiting it out
  # and then sending the model back to work would restart the job with the window
  # possibly still full — the one outcome worse than stopping too early.

  # A Stop hook that continues its own continuation loops forever and burns the
  # window it exists to protect. Two things prevent it, both on this side: the
  # pause is lifted and read back from disk before the answer is written, so the
  # next stop finds nothing to hold, and a resume that fired in the last minute
  # refuses to fire again.
  #
  # The harness's own `stop_hook_active` marker is deliberately not consulted.
  # Reading stdin at all lets a pipe that is never written hang the end of the
  # turn, and the marker stays true for every stop in a chain the hook itself
  # continued — so honouring it would silently kill the resume the second time a
  # long session hit the wall, which is exactly the case this exists for.
  [ $(( $(date +%s) - $(mtime "$RESUMED") )) -lt 60 ] && exit 0

  # The pause is recorded once for the account, not once per session, so every
  # open window sees blocked=1 and would hold its own turn and be force-resumed
  # at the rollover — N model turns spending the window that was just protected,
  # in sessions with no interrupted work to continue. One holder at a time: the
  # first turn to end during the pause. mkdir is the lock, as in the probe.
  if ! mkdir "$HOLD" 2>/dev/null; then
    local hpid
    hpid=$(head -c 16 "$HOLD/pid" 2>/dev/null | tr -cd '0-9')
    # A holder killed with its session must not lock the feature out forever.
    [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null && exit 0
    mv "$HOLD" "$HOLD.stale.$$" 2>/dev/null || exit 0
    rm -rf "$HOLD.stale.$$" 2>/dev/null
    mkdir "$HOLD" 2>/dev/null || exit 0
  fi
  printf '%s' "$$" > "$HOLD/pid" 2>/dev/null
  trap 'rm -rf "$HOLD" 2>/dev/null' EXIT

  # Sleep in short spans instead of one long one, re-reading state each time, so
  # a pause lifted from another terminal (`threshold 99`, `off`) is noticed and
  # the turn ends rather than sitting until the original reset time.
  local now deadline left rollover=0 keep_reading="" graced="" grace_until=0
  now=$(date +%s)
  deadline=$(( now + WINDOW_SECONDS + 300 ))
  while :; do
    load_state || break
    # Asked before the pause itself, because a guard switched off mid-wait must
    # end the turn quietly whatever the state file says next.
    [ "$(enabled)" = "1" ] || break
    now=$(date +%s)
    if [ "$S_blocked" != "1" ]; then
      # The pause is one flag for the whole account, so any other session's tool
      # call can release it on the clock while this turn is parked here. The
      # pause is gone, but the rollover it came from is this loop's rollover, and
      # ending quietly strands the work the wait exists to restart. A reset still
      # ahead means it was lifted by hand instead, which ends the wait and
      # restarts nothing, as it always has.
      [ -n "$S_reset" ] && [ "$S_reset" -gt 0 ] && [ "$now" -ge "$S_reset" ] && rollover=1
      break
    fi
    if [ "$now" -ge "$deadline" ]; then
      # Out of time. Ending silently is right for a turn that never reached its
      # rollover, but not for one that did and was only waiting out the grace on
      # this very reset: that restart is already owed, and swallowing it loses
      # the work for the sake of a reading a minute fresher. Matched against the
      # current reset, not merely "graced at some point", so a probe that moved
      # the reset on and then went quiet for a whole window does not come back
      # here to restart on a reading that never cleared.
      [ "$graced" = "$S_reset" ] && rollover=1
      break
    fi
    # A held turn makes no tool calls, so nothing else refreshes the reading it
    # is waiting on. Without this the only news it could ever receive was a probe
    # some other session happened to run, and a lone paused session slept blind
    # through the rollover it was holding the turn open for.
    maybe_refresh
    # The rollover can land earlier than the reset time recorded when the pause
    # began, and when it does the probe writes the new window's percentage next
    # to a reset time five hours further out — so waiting on that time sits out
    # a window that already restarted, until the deadline ends the turn with no
    # resume at all. The reading is the rollover; take it as one.
    if reading_cleared; then rollover=1; keep_reading=keep; break; fi
    # A corrupt or missing reset time is not a rollover and never becomes one, so
    # the wait ends here rather than hanging on a moment that will not arrive.
    # Releasing the pause is left to the gate, which does it on the next call.
    [ -n "$S_reset" ] && [ "$S_reset" -gt 0 ] || break
    left=$(( S_reset - now ))
    if [ "$left" -le 0 ]; then
      # First time this reset time comes due, do not answer on it. Force a read,
      # wait out the grace, and come round again: by then the account reports the
      # new window, `reading_cleared` sees it above, and the release keeps that
      # reading instead of the one belonging to the window that just closed. If
      # the new reading says the window is genuinely still full, the probe has
      # also written the next reset time and this loop simply waits for it.
      #
      # Only once per reset time, so a probe that never lands cannot spin here:
      # the second time the same moment comes due, the turn is restarted on the
      # old terms, which is what it did before this existed.
      # A guessed reset coming due proves nothing: the guess was a whole window
      # long precisely so it could not end a pause, and restarting here would put
      # the model back to work against an account that may still be full. The
      # reading is what ends this wait, and it is checked above on every pass.
      [ "${S_est:-0}" = "1" ] && break
      if [ "$graced" != "$S_reset" ]; then
        graced="$S_reset"
        grace_until=$(( now + RESUME_GRACE ))
        # The TTL is what usually holds a refresh back, and a reading taken
        # before the rollover is exactly the one not to wait on.
        S_fetched=0
        maybe_refresh
      fi
      # Poll rather than sleep the grace out in one go. The account usually
      # agrees within a probe or two, and `reading_cleared` above sees that on
      # the next pass and answers then instead of at the end of the minute; the
      # short spans also keep the guard, the pause and the deadline live
      # throughout, which one long sleep did not.
      if [ "$now" -lt "$grace_until" ]; then
        left=$(( grace_until - now ))
        [ "$left" -gt 5 ] && left=5
        sleep "$left"
        continue
      fi
      rollover=1; break
    fi
    [ "$left" -gt 30 ] && left=30
    sleep "$left"
  done

  # Every other way out of that loop — state gone, guard switched off, cap
  # reached, reset unreadable — ends the turn silently. Only the window actually
  # rolling over may put the model back to work.
  [ "$rollover" = "1" ] || exit 0

  release $keep_reading
  # A release that did not reach disk leaves blocked=1 behind, and then every
  # following turn end would resume again, one turn a minute, for as long as the
  # disk stays unwritable. Confirm the pause is really gone before answering.
  load_state || exit 0
  [ "$S_blocked" = "1" ] && exit 0
  maybe_refresh
  # Releasing disarms the timer that would have announced the rollover, and the
  # timer may never have been armed at all, so the announcement is made here
  # rather than left to whichever of the two woke first.
  notify "Session window reset — resuming the paused work."
  resume_answer
}

# ---------------------------------------------------------------------------
# check — the PreToolUse gate
# ---------------------------------------------------------------------------
do_check() {
  # A guard that is wired wrong fails by doing nothing, which looks identical to
  # a guard with nothing to report. This heartbeat is how `status` tells the
  # difference. touch, not `: >`, so an unexpected symlink here is harmless.
  [ -z "$REFUSED" ] && touch "$LASTCHECK" 2>/dev/null
  [ "$(enabled)" = "1" ] || exit 0
  [ -n "$REFUSED" ] && exit 0
  # Reaching a tool call at all means the work is moving, so whatever the last
  # denial recorded is spent. The deny branches below write it again; keeping it
  # any longer would leave a restart owed to work that already carried on.
  [ -f "$PENDING" ] && rm -f "$PENDING" 2>/dev/null
  load_state || { maybe_refresh; exit 0; }
  maybe_refresh

  local now th left
  now=$(date +%s); th=$(threshold)
  if [ -n "$S_reset" ]; then left=$(( S_reset - now )); else left=0; fi

  if [ "$S_blocked" = "1" ]; then
    # Releasing on a bogus epoch too. Requiring epoch > 0 made a zero or missing
    # value an unbreakable pause: every tool denied forever, including the one
    # that would lift it, so the only way out was an external terminal.
    # The clock striking is not the window turning over — for a short while after
    # it the account still reports the window that just closed. Releasing on the
    # instant handed out permission on a percentage nobody had measured yet, and
    # the reading that landed a second later denied the same tool again. The gate
    # is where every other session meets the rollover, so it waits out the same
    # grace the held turn does. A missing or bogus reset time still releases at
    # once: that release exists to break a deadlock, and delaying it re-creates
    # the deadlock it is for.
    if [ -z "$S_reset" ] || [ "$S_reset" -le 0 ] || [ $(( left + RESUME_GRACE )) -le 0 ]; then
      release
      notify "Session window reset — Keeper released the pause."
      maybe_refresh
      exit 0
    fi
    # The reset time is only a prediction, so it is not the only way out. A
    # reading already under the threshold is the window reporting its own
    # rollover, hours before the predicted moment, and holding the pause against
    # it denies every tool — including the one that would lift it.
    if reading_cleared; then
      release keep
      notify "Session window reset — Keeper released the pause."
      maybe_refresh
      exit 0
    fi
    arm_timer "$left" "$S_reset"
    mark_pending 2>/dev/null
    deny "KEEPER PAUSE ACTIVE. Session window at ${S_pct:-unknown}% (limit ${th}%). All tools stay blocked $(blocked_for "$left"). $STOP_INSTRUCTIONS"
    exit 0
  fi

  # An unknown percentage must not read as 0, but it must not block either:
  # blocking on corrupt state is the failure that cannot be undone from inside
  # the session. Allow, and let status and the badge shout about it.
  [ -n "$S_pct" ] || exit 0

  if [ "$S_pct" -ge "$th" ]; then
    set_field blocked 1
    arm_timer "$left" "${S_reset:-0}"
    notify "Session window at ${S_pct}% — work paused$(until_phrase)."
    mark_pending 2>/dev/null
    deny "KEEPER TRIPPED at ${S_pct}% of the 5-hour session window (limit ${th}%). All tools are now blocked $(blocked_for "$left"). $STOP_INSTRUCTIONS"
    exit 0
  fi
  exit 0
}

# ---------------------------------------------------------------------------
probe_error() { [ -z "$REFUSED" ] && [ -f "$PROBE_ERR" ] && head -c 120 "$PROBE_ERR" 2>/dev/null | tr -cd 'a-zA-Z0-9 ;:/.,()-'; }

do_session_start() {
  [ "$(enabled)" = "1" ] || exit 0
  if [ -n "$REFUSED" ]; then
    printf 'KEEPER DISABLED — its state file is a symlink and is refused, so the 5-hour session window is NOT being guarded. Tell the user to remove %s.\n' "$REFUSED"
    exit 0
  fi
  load_state || true
  maybe_refresh
  local th err
  th=$(threshold); err=$(probe_error)
  if [ -n "$S_pct" ]; then
    printf 'KEEPER ACTIVE — 5-hour session window at %s%% used, pause threshold %s%%%s.\n' \
      "$S_pct" "$th" "$([ -n "$S_label" ] && [ "${S_est:-0}" != "1" ] && printf ', resets %s' "$S_label")"
  else
    printf 'KEEPER ACTIVE — pause threshold %s%% of the 5-hour session window; reading it now.\n' "$th"
  fi
  [ -n "$err" ] && printf 'Keeper probe problem: %s — the reading may be stale, so say so if usage matters.\n' "$err"
  printf 'If a tool comes back denied with a KEEPER message, that is the pause: stop at once, no retries and no working around it in prose, and tell the user when it releases.\n'
}

do_status() {
  if [ -n "$REFUSED" ]; then
    printf 'Keeper: DISABLED — refusing to use %s because it is a symlink\n' "$REFUSED"
    printf 'The 5-hour window is NOT being guarded. Remove that file to restore Keeper.\n'
    return 0
  fi
  load_state || true
  local th err now
  th=$(threshold); err=$(probe_error); now=$(date +%s)
  printf 'Keeper: %s\n' "$([ "$(enabled)" = 1 ] && echo enabled || echo disabled)"
  if [ -n "$S_pct" ]; then
    printf 'Session window: %s%% used (threshold %s%%)\n' "$S_pct" "$th"
  else
    printf 'Session window: unknown (threshold %s%%)\n' "$th"
  fi
  if [ -n "$S_reset" ] && [ "$S_reset" -gt 0 ]; then
    printf 'Resets: %s (in %s)%s\n' "${S_label:-unknown}" "$(human_left $(( S_reset - now )))" \
      "$([ "${S_est:-0}" = "1" ] && printf ' [estimated]')"
  fi
  printf 'Paused: %s\n' "$([ "$S_blocked" = 1 ] && echo yes || echo no)"
  if [ -n "$S_fetched" ] && [ "$S_fetched" -gt 0 ]; then
    printf 'Reading age: %ss (refresh every %ss at this level)\n' \
      "$(( now - S_fetched ))" "$(ttl_for "$S_pct")"
  else
    printf 'Reading age: no reading yet\n'
  fi
  [ -n "$err" ] && printf 'Probe problem: %s\n' "$err"
  if [ -f "$LASTCHECK" ]; then
    printf 'Gate last consulted: %ss ago\n' "$(( now - $(mtime "$LASTCHECK") ))"
  else
    printf 'Gate: never consulted — hooks may need a session restart to load\n'
  fi
}

case "${1:-check}" in
  check)         do_check ;;
  stop)          do_stop ;;
  session-start) do_session_start ;;
  probe)         do_probe ;;
  status)        do_status ;;
  ttl)           ttl_for "$(printf '%s' "${2:-0}" | tr -cd '0-9')" ;;
  threshold)
    v=$(printf '%s' "${2:-}" | tr -cd '0-9')
    if [ -z "$v" ] || [ "$v" -lt 1 ] || [ "$v" -gt 100 ]; then
      printf 'Threshold must be 1-100; kept %s%%\n' "$(threshold)"; exit 1
    fi
    write_config "$v" "$(enabled)"
    # A raised threshold should lift an active pause immediately rather than
    # waiting for the window to roll over — it is the escape hatch for deciding
    # the remaining budget is yours to spend.
    load_state || true
    if [ -n "$S_pct" ] && [ "$S_pct" -lt "$v" ]; then set_field blocked 0; disarm_timer; fi
    printf 'Keeper threshold set to %s%%\n' "$v" ;;
  on)  write_config "$(threshold)" 1; printf 'Keeper enabled (threshold %s%%)\n' "$(threshold)" ;;
  # Switching the guard off ends the pause on purpose, so there is no interrupted
  # work owed a restart. Left behind, the record would fire one at whatever turn
  # ended next after `on`, announcing a rollover that never happened.
  off) write_config "$(threshold)" 0; set_field blocked 0; rm -f "$PENDING" 2>/dev/null; disarm_timer; printf 'Keeper disabled\n' ;;
  *)   printf 'usage: keeper.sh {check|stop|session-start|probe|status|threshold N|on|off}\n'; exit 1 ;;
esac
