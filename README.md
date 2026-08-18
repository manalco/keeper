# Keeper

[![status](https://img.shields.io/badge/status-active-108C4A?style=flat-square)](#)
[![self--check](https://img.shields.io/badge/self--check-108%2F108%20passing-2E7D32?style=flat-square)](#self-check)
[![token cost](https://img.shields.io/badge/token%20cost-~69%20tokens%2Fsession-1565C0?style=flat-square)](#what-it-costs)
[![probe](https://img.shields.io/badge/probe-0%20API%20calls-1565C0?style=flat-square)](#how-it-works)
[![threshold](https://img.shields.io/badge/default%20threshold-95%25-D97706?style=flat-square)](#configuration)
[![platform](https://img.shields.io/badge/platform-macOS%20%C2%B7%20Linux-555555?style=flat-square)](#requirements)
[![deps](https://img.shields.io/badge/dependencies-python3%20%2B%20claude-555555?style=flat-square)](#requirements)
[![license](https://img.shields.io/badge/license-CC%20BY--NC--SA%204.0-8E44AD?style=flat-square)](#license)
[![author](https://img.shields.io/badge/author-Manuel%20Alvarado-1F2937?style=flat-square)](#license)

Guards the account's **5-hour Claude session window**. Watches the percentage,
pauses every tool before the limit lands, holds the interrupted turn open across
the rollover, and picks the work back up by itself when the window resets.

The problem it solves: hitting the window limit in the middle of a long task
loses whatever was in flight. Keeper stops the work on purpose, with the budget
intact, instead of having it stop by force.

```
[KEEPER:33%]                 normal, green
[KEEPER:88%]                 approaching the threshold, amber
[KEEPER:96% BLOCKED 2h14m]   paused, red, counting down
[KEEPER:33%~]                percentage exact, reset time estimated
[KEEPER:33%?]                reading older than its refresh interval
[KEEPER:?]                   no reading yet, grey
[KEEPER:!]                   no usable reading and a recorded reason, red
[KEEPER:OFF]                 guarding disabled
```

The suffixes are deliberately graded. `~` means the percentage — the number the
guard actually decides on — is exact and only the reset time is a guess, so the
guard is working. `!` is reserved for having no usable percentage at all. An
earlier version raised `!` for both, which fired on every window rollover and
taught the reader to ignore it.

The badge appends itself to whatever the statusline already renders, so it sits
alongside any other segments you have configured.

## How it works

The percentage comes from `claude -p "/usage"`. The CLI answers that command
**locally** — the resulting session transcript contains no assistant turn and no
`usage` record, so the reading costs **zero API tokens**.

What it does cost is wall clock: ~40s normally, cut to **~12s** with
`--strict-mcp-config --mcp-config '{"mcpServers":{}}'`. That is far too slow to
sit in front of a tool call, so the design separates measuring from deciding:

| Piece | Trigger | Work it does | Latency |
|---|---|---|---|
| `keeper.sh probe` | detached, on demand | reads `/usage`, writes cache, deletes its own throwaway transcript | ~12s, off the critical path |
| `keeper.sh check` | `PreToolUse`, every tool | compares cached number to threshold | ~26ms |
| `keeper.sh session-start` | `SessionStart` | prints current usage + the stop rule | ~22ms |
| `keeper-statusline.sh` | every render | prints the badge from cache, never probes | ~11ms |

Those are measured medians on macOS, and most of each one is `bash` process
startup rather than the script's own work. They are ~500x cheaper than the probe,
which is the point of the split, but they are not free: `check` adds roughly
26ms to every tool call. Each script reads its state file in a single pass with
no subprocesses — the earlier field-by-field version cost ~30 forks per render
and took 70ms.

Refresh cadence adapts, because a stale reading only matters near the wall:

| Usage | Re-reads every |
|---|---|
| below 70% | 10 min |
| 70–89% | 3 min |
| 90%+ | 90 s |

### The pause and the timer

At or above the threshold, `PreToolUse` returns a `deny` decision for **every**
tool, fires a desktop notification, and arms a detached timer that sleeps until
the reset moment and announces the rollover. Nobody has to watch the clock.

Once the reset time passes, the next hook call clears the pause, records `0`
(the window genuinely restarts empty, and keeping the stale high reading would
re-block the very next tool call) and zeroes the reading's timestamp so a fresh
probe runs immediately rather than trusting that `0`.

A pause also lifts on a *bogus* reset time, not only a past one. Requiring a
valid timestamp to release made a zero or corrupt value an unbreakable pause:
every tool denied indefinitely, including the command that would lift it, so the
only way out was an external terminal.

In the moments right after a rollover, `/usage` still names the window that just
ended. A reset label in the past therefore is not an error — the window is five
hours long, so the next reset is that label plus five hours, and Keeper steps it
forward rather than flagging it. Reading it as unreadable instead put an alarming
badge on the statusline at every single rollover and pinned it there for the
length of the failure backoff.

### Resuming the work, not just releasing the gate

Lifting the pause is not the same as continuing the job. The turn that hit the
wall had already ended, and nothing re-invokes the model, so the work used to sit
there — gate open, window fresh — until a human noticed and typed something. That
was the whole point of pausing, lost at the last step.

The `Stop` hook closes it. When a turn ends while the pause is active, Keeper
holds that turn open instead of letting the session go idle: a sleeping shell,
waking every 30s to re-read the state file, spending **nothing** while it waits.
When the reset arrives it lifts the pause and answers the hook with a `block`
decision, which is how a `Stop` hook says *keep going* — the same conversation,
with its full context, carries on where it stopped. Releasing disarms the timer
that would have announced the rollover — and that timer may never have been armed
— so the resume makes the announcement itself.

Four properties matter more than the mechanism:

- **Only a real rollover restarts a turn.** The wait also ends if the state file
  disappears, if the guard is switched off from another terminal, if the cap is
  reached, or if the reset time is unreadable — and every one of those ends the
  turn silently instead of putting the model back to work. "I stopped waiting" is
  not "the window reset".
- **An estimated reset never resumes.** When the probe cannot parse the reset
  clause it stores a placeholder fifteen minutes out. Waiting that out and then
  resuming would send the model back to work with the window still full, so a
  reading marked `~` holds nothing open.
- **One session is held, not all of them.** The pause is recorded once for the
  account, so every open window sees it. Without an exclusive hold each would
  freeze its own turn and be force-resumed at the rollover — N model turns
  spending the window that was just protected, in sessions with no interrupted
  work to continue. The first turn to end during the pause takes an `mkdir` lock;
  the rest are let go immediately, and a holder that dies with its session is
  taken over rather than locking the feature out.
- **It never loops.** The pause is lifted *and read back from disk* before the
  answer is written, so the next stop finds nothing to hold; a release that
  failed to persist leaves `blocked=1` behind, and answering anyway would resume
  a turn every minute for as long as the disk stayed unwritable. A resume that
  fired in the last minute also refuses to fire again. Keeper does not consult
  the harness's `stop_hook_active` marker: reading stdin at all lets an unwritten
  pipe hang the end of a turn, and the marker stays true for every stop in a
  chain the hook itself continued — honouring it would silently kill the resume
  the *second* time a long session hit the wall, which is the case this exists
  for.
- **A pause lifted by hand is noticed.** Raising the threshold from another
  terminal releases the state file, and the sleeper picks that up on its next
  30s wake rather than sitting until the original reset.

Honest limit: this depends on the hook being allowed to run as long as the wait.
Claude Code kills a hook at its configured `timeout`. Keeper caps its own wait at
one window plus five minutes (18300s), so the wiring below sets `18420` — two
minutes above that cap, because a timeout equal to the cap kills the hook at the
same instant it would have answered. If a harness caps that lower, the hook
is killed, the turn ends, and Keeper degrades to exactly the old behaviour: the
pause still releases itself, the desktop notification still fires, and the work
waits for you to type. Nothing is lost either way; the resume is what you lose. The same is true of a
reset time Keeper could not read: it guards, it pauses, it releases — it just
will not restart the turn on a number it had to guess.

## What it costs

| Component | Tokens per session |
|---|---|
| `/usage` probe | **0** — no API call, verified in the transcript |
| `PreToolUse` below threshold | **0** — no output, so nothing enters context |
| Statusline badge | **0** — the statusline is never part of context |
| `SessionStart` block | ~69 (254 characters, 47 words, asserted under 120 words by the self-check) |
| Trip event, per denied call | ~85 |
| Holding a paused turn open | **0** — a sleeping shell, no model involved |
| The resume instruction | ~90 — the `reason` the hook injects to restart the turn |
| The resumed turn itself | one ordinary turn, in the *new* window it just waited for |

## Configuration

```bash
bash ~/.claude/skills/keeper/hooks/keeper.sh status        # percentage, reset time, paused?, reading age
bash ~/.claude/skills/keeper/hooks/keeper.sh probe         # force a fresh reading (~12s)
bash ~/.claude/skills/keeper/hooks/keeper.sh threshold 90  # move the pause point (1-100)
bash ~/.claude/skills/keeper/hooks/keeper.sh off           # stop guarding
bash ~/.claude/skills/keeper/hooks/keeper.sh on            # resume guarding
```

Raising the threshold above the current percentage lifts an active pause on the
spot — the escape hatch for deciding the remaining budget is yours to spend.

Run that command from a normal terminal, not from inside the paused session:
while the pause is active every tool call is denied by design, which includes the
one that would lift it.

Files:

| Path | Role |
|---|---|
| `~/.claude/skills/keeper/hooks/keeper.sh` | probe, gate, session block, the held-open turn, config |
| `~/.claude/skills/keeper/hooks/keeper-statusline.sh` | `[KEEPER:NN%]` badge |
| `~/.claude/skills/keeper/hooks/keeper-selfcheck.sh` | 108 offline assertions |
| `~/.claude/skills/keeper/SKILL.md` | the control-surface skill |
| `~/.claude/.keeper-state` | cached reading (`pct`, `reset_epoch`, `blocked`) |
| `~/.claude/.keeper-config` | `threshold=95`, `enabled=1` |
| `~/.claude/.keeper-lastcheck` | heartbeat proving the gate is wired |
| `~/.claude/.keeper-timer.pid` | the armed rollover sleeper, as `pid epoch` |
| `~/.claude/.keeper-probe-error` | why the last reading failed, if it did |
| `~/.claude/.keeper-probe-attempt` | when it last tried, so failures back off |

`status` reports `Gate last consulted: Ns ago`. If it ever says the gate was
never consulted, the hooks are not loaded and Keeper is watching nothing — that
line exists because a misconfigured guard is indistinguishable from a quiet one.

Wiring lives in `~/.claude/settings.json`: a `SessionStart` hook, a `PreToolUse`
hook matching all tools, a `Stop` hook, and a segment appended to `statusLine`.
The `Stop` hook is the one with a non-default timeout — it has to outlast
Keeper's own 18300s cap on the wait:

```json
"Stop": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "bash \"$HOME/.claude/skills/keeper/hooks/keeper.sh\" stop",
        "timeout": 18420
      }
    ]
  }
]
```

## Self-check

```bash
bash ~/.claude/skills/keeper/hooks/keeper-selfcheck.sh
```

108 assertions, fully offline against a fixture in a throwaway `KEEPER_HOME`, so
it needs no network and never touches real state. Covers percentage parsing,
timezone-aware reset math, the dateless `resets 3:50pm` variant, inclusive
threshold, auto-release, the held-open turn and its loop guard, percentage
zeroing, config validation, refresh cadence, badge colors, the countdown, and
every item under Hardening below.

Reset clauses in the fixtures are generated relative to now. They were once
hardcoded to a specific date and hour, which meant the suite proved nothing the
following morning while still reporting green. Two hardening assertions were
also vacuous — one planted escape sequences in a field the badge never prints,
the other symlinked a file containing no state — so both passed with the
protections deleted. Both now fail without them.

## Hardening

The state file lives in the user's home, so any local process can write it. Its
contents then reach three places that matter: the terminal on every keystroke,
the deny reason and session block that enter the model's context, and shell
arithmetic. Treating the file — not the code that writes it — as the trust
boundary is what the measures below have in common.

- **Filtered on read, not on write.** Every field is reduced to the characters
  its role allows (digits for the percentage, `[0-9:apm]` for the clock label)
  as it is loaded. Filtering only at the write site left a hand-edited,
  half-written, or older-format file unprotected.
- **The clock label cannot reshape the deny JSON.** It reaches
  `permissionDecisionReason` and the `SessionStart` block, both read as context.
  Unescaped, a crafted label could close the JSON object early and append
  `"permissionDecision":"allow"` — defeating the pause on a last-key-wins parser
  — or inject instructions the model reads with the guard's authority.
- **Temp files use `mktemp`, not `$FILE.$$`.** A pid is a small guessable
  integer, so symlinks pre-planted across a range of pids could capture the
  write, overwrite any file the user owns, and leave the state file itself a
  symlink — which the refusal below would then turn into a permanent silent
  bypass.
- **Symlinks at the state, config, heartbeat, timer, and resume-marker paths are
  refused**, and
  the refusal is reported by `status`, the badge, and the session block. Refusing
  silently disabled the guard *and* muted the only tool for noticing.
- **The percentage is clamped on read.** All-digit garbage passes a numeric
  filter but overflows the comparison, and bash reads that error as false — which
  meant no block at full usage.
- **The rollover timer receives its data as arguments**, never spliced into a
  `sh -c` string: a single quote in `KEEPER_HOME` or `CLAUDE_CONFIG_DIR`
  otherwise closed the quoting and the remainder became code in a detached
  process outliving the session.
- **The held-open turn is the one place Keeper waits on the state file, and it
  waits synchronously.** Any local process that can write `~/.claude/.keeper-state`
  can set `blocked=1` with a distant `reset_epoch` and stall the end of a turn for
  up to the 18300s cap. That is a real consequence of this design, stated rather
  than hidden: the same write could already deny every tool indefinitely, the cap
  and the harness timeout bound it, and interrupting the session ends it at once.
- **`PATH` is pinned to system directories first**, so a venv, direnv, or
  `node_modules/.bin` shim cannot substitute the parser or the comparison tools.
- **State is parsed field-by-field, never sourced**, and reads are capped at 512
  bytes.
- **Writes are atomic** (`mktemp` + `mv`), and the probe holds an `mkdir` lock
  whose stale entry is claimed by rename, so two racers cannot both clear it and
  both proceed.
- **Transcript cleanup deletes only the exact directory the probe created.** The
  earlier unanchored glob would also have matched a real project whose path ends
  in `keeper-probe`, and `rm -rf`'d its history every 90 seconds.

## Limits

Stated plainly, because a guard that oversells itself is worse than none:

1. **It gates tools, not text.** The denial instructs the stop; it cannot
   physically prevent a reply from being written.
2. **A subagent mid-call finishes that call.** The block lands on its next one.
   With subagent-heavy sessions there can be a few seconds of overshoot — which
   is why the default leaves 5% of headroom instead of sitting at 99%.
3. **The window is per account**, spanning other machines and claude.ai. The
   percentage itself comes from the server and is accurate; only the usage
   attribution breakdown in `/usage` is local to this machine.
4. **Ambiguity resolves toward allowing.** If the reading is unknown or the state
   file is corrupt, Keeper lets the tool through and says so loudly in `status`,
   the badge, and the session block rather than blocking. Failing open wastes the
   budget this exists to protect; failing closed strands the user, since the
   command that lifts a pause is itself denied. The visible-failure signals are
   there because that choice only works if you can see it was made.

## Requirements

`bash` (3.2 is fine), `python3` for timezone-aware reset math, and the `claude`
CLI on `PATH`. Nothing to install beyond those.

## Platforms

Runs on macOS and on any Linux distribution. Every command it calls is either
POSIX or probed for before use, and the two places where the platforms genuinely
disagree are handled explicitly:

| Concern | How it is handled |
|---|---|
| `stat` | GNU `stat -c %Y` is tried first, then BSD `stat -f %m`, and the result is validated as digits before any arithmetic |
| `timeout` | Used when present, skipped when not — it is GNU coreutils and does **not** ship with macOS |
| Notifications | `osascript` on macOS, `notify-send` on Linux, silently skipped when neither exists |
| `setsid` | Never used; it is absent on macOS. Detaching is done with `nohup` |
| Date arithmetic | `date +%s` only — no `date -v`, no `date -d` |
| In-place edits | None; writes go through `mktemp` + `mv` |
| Shell features | Process substitution and `${var//pattern/}` require bash, and all three scripts declare `#!/usr/bin/env bash` |

The `stat` ordering deserves a note, because getting it backwards fails in a way
that is easy to miss: GNU `stat` reads `-f %m` as a *filename*, prints a
multi-line filesystem report to stdout, and exits 1. Trying the BSD form first
therefore ran the fallback too, and the caller received the report and the
timestamp concatenated — which broke the probe lock, the failure backoff, and
`status` on every Linux machine while working perfectly on macOS.

Two Linux caveats worth stating plainly:

- **`notify-send` needs a session bus.** On a headless server or in a container
  there is nothing to notify, so the pause announces itself only through the
  badge. The guard still works; the announcement does not.
- **`zoneinfo` needs `tzdata`.** Minimal images (alpine, `python:slim`) often
  omit it. The probe already falls back to local time when the named timezone
  cannot be loaded, so the guard works; installing `tzdata` just makes the reset
  label exact.

Tested directly on macOS. The Linux paths are exercised by the self-check's
portability assertions and by running the `stat` logic against GNU `stat`, which
is not the same as a full run on a Linux box — if you run it there, the
self-check is the thing to run first.

## License

Copyright © Manuel Alvarado.

Licensed under [Creative Commons Attribution-NonCommercial-ShareAlike 4.0
International](https://creativecommons.org/licenses/by-nc-sa/4.0/) (CC BY-NC-SA
4.0). You may share and adapt this work, provided you credit the author, do not
use it commercially, and license derivative work under the same terms. Full text
in [LICENSE](LICENSE).
