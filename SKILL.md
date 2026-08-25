---
name: keeper
description: Inspect and configure Keeper, the always-on guard that watches the account's 5-hour Claude session window and pauses all tool use before the limit is hit. Use this skill whenever the user asks how much of the session or 5-hour window is used, how long until the window resets, why tools are blocked or denied, why a tool call seems frozen or stuck for a long time, or wants to change, raise, lower, check, enable, or disable the pause threshold — including phrasings like "cuánto uso llevo", "cuánto queda de la ventana", "por qué está bloqueado", "por qué está congelado", "sube el umbral", "desactiva Keeper", "/keeper", "keeper status", "session usage", or "rate limit guard". Also use it when a tool call comes back denied with a KEEPER message and the situation needs explaining to the user.
---

# Keeper

Keeper watches the account's 5-hour session window and pauses all tool use before
it runs out, so a long task never dies mid-edit with unsaved work. The pause is a
wait, not a refusal: the tool call is held until the window rolls over and then
runs, so the agent that hit the limit carries on by itself — subagents included,
which a denial could never do. It is wired as hooks, not as instructions to
follow — by the time you read this, it is already running. This skill is the
control surface: reading state and changing settings.

## How it works, in one pass

- `~/.claude/skills/keeper/hooks/keeper.sh probe` runs `claude -p "/usage"`. The CLI answers
  that locally, with no API request, so measuring costs **zero tokens**. It takes
  ~12s of wall clock, so the probe always runs detached and every hook decides
  from the cached reading in milliseconds.
- `SessionStart` prints the current percentage and the stop rule.
- `PreToolUse` allows silently below the threshold. At or above it, the call is
  **held**: the hook sleeps, waking every 15s to re-read the state, and returns
  only once the window has rolled over — at which point the held tool call simply
  runs. Waiting costs no tokens, and nothing has to resume anything, because the
  held call is itself the continuation. A desktop notification fires when the
  pause starts and when it lifts.
- The wait is capped at 18300s, just under the `timeout` the `PreToolUse` hook is
  wired with. That order matters: a hook the harness cancels contributes no
  decision at all and the tool then runs, so Keeper always answers first. When
  the cap runs out before the window turns over, it falls back to denying, which
  is the rare case the resume machinery below still covers.
- When a pause does end in a denial, a detached timer sleeps until the reset
  moment and announces the rollover, so a stopped session needs nobody watching
  the clock. A held call needs no timer: it announces its own release.
- The restart waits about a minute past the reset before it fires, and reads the
  window again first, and the gate keeps the pause through that minute rather
  than releasing the instant the clock strikes. For a short while after a
  rollover `/usage` still reports the window that just ended, percentage
  included, and acting on that reading got the next tool call denied a second
  later.
- The pause releases itself once the reset time passes; the cached percentage is
  set to 0 because the window genuinely restarts empty. It also releases as soon
  as a fresh reading lands under the threshold, which is how a window that rolls
  over earlier than predicted announces itself — that reading is kept, not zeroed,
  because it is already the new window's.
- `Stop` holds the interrupted turn open across the rollover and then answers
  `block`, which restarts the same turn with its context intact — so the work
  resumes on its own instead of waiting for the user to type. Waiting is a
  sleeping shell and costs nothing, and it refreshes the reading as it goes, so
  an early rollover ends the wait instead of sleeping through it. Only a real
  rollover restarts the turn: a guard switched off
  mid-wait, or an unreadable state file all end the turn quietly instead.
- While a call is held the session looks frozen and the model says nothing — no
  denial reaches it, which is the point. The statusline badge is the signal:
  `[KEEPER:96% BLOCKED 2h14m]`, counting down to the window that frees it.
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
bash ~/.claude/skills/keeper/hooks/keeper-selfcheck.sh     # offline assertions, no tokens
```

`status` also prints `Gate last consulted: Ns ago`. If that line ever reads
"never consulted", the hooks are not loaded and Keeper is guarding nothing —
worth saying out loud rather than assuming silence means safety.

When the user asks how much is left, prefer `status` over a fresh `probe` — the
reading is usually minutes old at most, and `probe` makes them wait ~12s. Reach
for `probe` when `status` reports a reading age above a few minutes and the exact
number matters, or right after a pause releases.

Raising the threshold above the current percentage lifts an active pause within
15s, which is the escape hatch when the user decides the remaining budget is
theirs to spend. Say what the new headroom is when you do it.

**Run it from a separate terminal.** While a call is held, every tool call in
that session is held too — including the Bash call that would run these commands,
and including this skill. There is no recovery from inside a paused session by
design; the pause is what protects the budget. `KEEPER_WAIT_CAP=0` in the
environment restores the old deny-on-the-spot behaviour if holding is ever the
wrong trade.

## When the session seems frozen

A tool call that takes minutes with no output and a red `BLOCKED` badge is the
hold, not a hang. Nothing is wrong and nothing needs restarting: the call is
parked until the window rolls over, and then it runs. If the user asks, say how
long is left — the badge carries it, and `status` from another terminal gives the
same number.

## When a tool comes back denied

A denial now means the hold ran out of cap before the window turned over, which
is uncommon. The denial text starts with `KEEPER`. That is the pause working as
designed, not a bug and not something to route around. Stop on the spot: no retrying the tool, no
substituting a different tool, no pressing on in prose as if the work continued.

Say plainly that Keeper paused the session, at what percentage, and for how long
— and that the work resumes by itself, so nobody has to sit and watch. Prefer the
duration over a clock time: the reset time is sometimes only an estimate, and the
duration never is.

Then end the turn. Ending it is what delivers the turn to the `Stop` hook, which
is the only thing that can restart the work: it holds the turn open across the
rollover, and it restarts a turn that ended just after the pause lifted. Neither
can reach a session that keeps talking instead of stopping, and asking the user
to reply turns an automatic restart into a job waiting on a human. Working around
the pause defeats the whole point — the budget it protects is what finishes the
job.

When the restart arrives it reads `KEEPER RESUME`. Continue the interrupted work
straight away; do not re-open the question with the user or replay what happened.
If it arrives in a session that had nothing interrupted — the record is per
account and per project, not per session — say so in one line and stop.

## Limits worth stating honestly

Keeper gates tools, not text, so it cannot physically stop a reply from being
written; a held call stops the work by not returning, and the denial at the cap
instructs the stop. The automatic resume needs the `Stop`
hook to be allowed to run for the length of the wait (`timeout: 18420` in
settings); if the harness kills it earlier, the pause still releases but the work
waits for the user's next message. A restart is only ever delivered at the end of
a turn, so a session whose turn already ended without being held waits too, and
a reset time that could not be read gives no countdown at all — the pause ends
on a reading below the threshold, or on a bound one window out. And a subagent already mid-tool-call
finishes that call — the hold lands on its next one, which is part of why the
default threshold leaves 5% of headroom rather than sitting at 99%.

The hold depends entirely on the `PreToolUse` hook being wired with a `timeout`
longer than the cap (`18420` against a cap of `18300`). Wired without it, the
harness cancels the hook mid-wait, contributes no decision, and the tool runs
unguarded at 96% — the one failure this guard cannot come back from. `status` and
the session block say so when they can see a wiring that cannot hold; they cannot
see one passed in by another route.
