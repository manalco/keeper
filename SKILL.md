---
name: keeper
description: Inspect and configure Keeper, the always-on guard that watches the account's 5-hour Claude session window and pauses all tool use before the limit is hit. Use this skill whenever the user asks how much of the session or 5-hour window is used, how long until the window resets, why tools are blocked or denied, or wants to change, raise, lower, check, enable, or disable the pause threshold — including phrasings like "cuánto uso llevo", "cuánto queda de la ventana", "por qué está bloqueado", "sube el umbral", "desactiva Keeper", "/keeper", "keeper status", "session usage", or "rate limit guard". Also use it when a tool call comes back denied with a KEEPER message and the situation needs explaining to the user.
---

# Keeper

Keeper watches the account's 5-hour session window and stops all tool use before
it runs out, so a long task never dies mid-edit with unsaved work. It is wired as
hooks, not as instructions to follow — by the time you read this, it is already
running. This skill is the control surface: reading state and changing settings.

## How it works, in one pass

- `~/.claude/skills/keeper/hooks/keeper.sh probe` runs `claude -p "/usage"`. The CLI answers
  that locally, with no API request, so measuring costs **zero tokens**. It takes
  ~12s of wall clock, so the probe always runs detached and every hook decides
  from the cached reading in milliseconds.
- `SessionStart` prints the current percentage and the stop rule.
- `PreToolUse` allows silently below the threshold. At or above it, every tool is
  denied and a desktop notification fires.
- A detached timer sleeps until the reset moment and announces the rollover, so a
  paused session needs nobody watching the clock.
- The pause releases itself once the reset time passes; the cached percentage is
  set to 0 because the window genuinely restarts empty.
- The statusline badge shows `[KEEPER:33%]`, coloured against the configured
  threshold, and `[KEEPER:96% BLOCKED 2h14m]` while paused. Suffixes are graded:
  `~` means the percentage is exact but the reset time is estimated, `?` means the
  reading is older than its refresh interval, and `[KEEPER:!]` means there is no
  usable reading at all. Only `!` means the guard is not guarding — do not report
  `~` as a failure.
- Runs on macOS and Linux; `status` reports anything degraded.

## Commands

Run these directly; they are plain shell and cost nothing but the call.

```bash
bash ~/.claude/skills/keeper/hooks/keeper.sh status        # percentage, reset time, paused?, reading age
bash ~/.claude/skills/keeper/hooks/keeper.sh probe         # force a fresh reading now (~12s)
bash ~/.claude/skills/keeper/hooks/keeper.sh threshold 90  # change the pause point (1-100)
bash ~/.claude/skills/keeper/hooks/keeper.sh off           # stop guarding
bash ~/.claude/skills/keeper/hooks/keeper.sh on            # resume guarding
bash ~/.claude/skills/keeper/hooks/keeper-selfcheck.sh     # 80 offline assertions, no tokens
```

`status` also prints `Gate last consulted: Ns ago`. If that line ever reads
"never consulted", the hooks are not loaded and Keeper is guarding nothing —
worth saying out loud rather than assuming silence means safety.

When the user asks how much is left, prefer `status` over a fresh `probe` — the
reading is usually minutes old at most, and `probe` makes them wait ~12s. Reach
for `probe` when `status` reports a reading age above a few minutes and the exact
number matters, or right after a pause releases.

Raising the threshold above the current percentage lifts an active pause
immediately, which is the escape hatch when the user decides the remaining budget
is theirs to spend. Say what the new headroom is when you do it.

## When a tool comes back denied

The denial text starts with `KEEPER`. That is the pause working as designed, not a
bug and not something to route around. Stop on the spot: no retrying the tool, no
substituting a different tool, no pressing on in prose as if the work continued.

Tell the user plainly that Keeper paused the session, at what percentage, and when
it releases. Then wait. Working around the pause defeats the entire point — the
budget it is protecting is what the next session needs to finish the job.

## Limits worth stating honestly

Keeper gates tools, not text, so it cannot physically stop a reply from being
written; the denial instructs the stop. And a subagent already mid-tool-call
finishes that call — the block lands on its next one, which is part of why the
default threshold leaves 5% of headroom rather than sitting at 99%.
