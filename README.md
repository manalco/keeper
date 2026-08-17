# Keeper

[![status](https://img.shields.io/badge/status-active-108C4A?style=flat-square)](#)
[![self--check](https://img.shields.io/badge/self--check-40%2F40%20passing-2E7D32?style=flat-square)](#self-check)
[![token cost](https://img.shields.io/badge/token%20cost-~0%20per%20session-1565C0?style=flat-square)](#what-it-costs)
[![probe](https://img.shields.io/badge/probe-0%20API%20calls-1565C0?style=flat-square)](#how-it-works)
[![threshold](https://img.shields.io/badge/default%20threshold-95%25-D97706?style=flat-square)](#configuration)
[![platform](https://img.shields.io/badge/platform-macOS%20%C2%B7%20bash-555555?style=flat-square)](#requirements)
[![deps](https://img.shields.io/badge/dependencies-none-555555?style=flat-square)](#requirements)

Guards the account's **5-hour Claude session window**. Watches the percentage,
pauses every tool before the limit lands, arms a timer for the rollover, and
releases itself when the window resets.

The problem it solves: hitting the window limit in the middle of a long task
loses whatever was in flight. Keeper stops the work on purpose, with the budget
intact, instead of having it stop by force.

```
[CAVEMAN] [PONYTAIL] [KEEPER:33%]                 normal
[CAVEMAN] [PONYTAIL] [KEEPER:88%]                 approaching the threshold
[CAVEMAN] [PONYTAIL] [KEEPER:96% BLOCKED 2h14m]   paused, counting down
```

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
| `keeper.sh check` | `PreToolUse`, every tool | compares cached number to threshold | ~5ms |
| `keeper.sh session-start` | `SessionStart` | prints current usage + the stop rule | ~5ms |
| `keeper-statusline.sh` | every render | prints the badge from cache | ~3ms, never probes |

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

Once the reset time passes, the next hook call clears the pause and sets the
cached percentage to `0` — the window genuinely restarts empty, and keeping the
stale high reading would re-block the very next tool call.

## What it costs

| Component | Tokens per session |
|---|---|
| `/usage` probe | **0** — no API call, verified in the transcript |
| `PreToolUse` below threshold | **0** — no output, so nothing enters context |
| Statusline badge | **0** — the statusline is never part of context |
| `SessionStart` block | ~60 (47 words, asserted under 120 by the self-check) |
| Trip event, once | ~150 |

## Configuration

```bash
bash ~/.claude/hooks/keeper.sh status        # percentage, reset time, paused?, reading age
bash ~/.claude/hooks/keeper.sh probe         # force a fresh reading (~12s)
bash ~/.claude/hooks/keeper.sh threshold 90  # move the pause point (1-100)
bash ~/.claude/hooks/keeper.sh off           # stop guarding
bash ~/.claude/hooks/keeper.sh on            # resume guarding
```

Raising the threshold above the current percentage lifts an active pause on the
spot — the escape hatch for deciding the remaining budget is yours to spend.

Run that command from a normal terminal, not from inside the paused session:
while the pause is active every tool call is denied by design, which includes the
one that would lift it.

Files:

| Path | Role |
|---|---|
| `~/.claude/hooks/keeper.sh` | probe, gate, session block, config |
| `~/.claude/hooks/keeper-statusline.sh` | `[KEEPER:NN%]` badge |
| `~/.claude/hooks/keeper-selfcheck.sh` | 40 offline assertions |
| `~/.claude/skills/keeper/SKILL.md` | the control-surface skill |
| `~/.claude/.keeper-state` | cached reading (`pct`, `reset_epoch`, `blocked`) |
| `~/.claude/.keeper-config` | `threshold=95`, `enabled=1` |
| `~/.claude/.keeper-lastcheck` | heartbeat proving the gate is wired |
| `~/.claude/.keeper-timer.pid` | the armed rollover sleeper |

`status` reports `Gate last consulted: Ns ago`. If it ever says the gate was
never consulted, the hooks are not loaded and Keeper is watching nothing — that
line exists because a misconfigured guard is indistinguishable from a quiet one.

Wiring lives in `~/.claude/settings.json`: a `SessionStart` hook, a `PreToolUse`
hook matching all tools, and a third segment appended to `statusLine`.

## Self-check

```bash
bash ~/.claude/hooks/keeper-selfcheck.sh
```

35 assertions, fully offline against a fixture in a throwaway `KEEPER_HOME`, so
it needs no network and never touches real state. Covers percentage parsing,
timezone-aware reset math, the dateless `resets 3:50pm` variant, inclusive
threshold, auto-release, percentage zeroing, config validation, refresh cadence,
badge colors, the countdown, and the hardening below.

## Hardening

The state file feeds a string that gets re-rendered to the terminal on every
keystroke, which makes it a genuine injection surface:

- Symlinked state or config files are refused, never followed — a planted link
  could otherwise stream any file's bytes into the statusline.
- Reads are capped at 512 bytes and filtered to `[a-zA-Z0-9:%.-]`, so ANSI
  escapes or OSC hyperlinks in a tampered file cannot reach the terminal.
- State is parsed field-by-field, never sourced, so a tampered file cannot
  execute anything.
- Writes are atomic (`tmp` + `mv`), and the probe holds an `mkdir` lock with a
  3-minute staleness bound so a crashed probe cannot wedge refreshes forever.
- The probe runs from its own directory, so cleanup deletes a folder it owns
  rather than guessing which transcript beside real ones is junk.

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

## Requirements

`bash`, `python3` (for timezone-aware reset math), and the `claude` CLI on
`PATH`. Desktop notifications use `osascript` on macOS and are skipped silently
elsewhere. No packages to install.
